package livestream

import (
	"context"
	"errors"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

type fakePubSub struct {
	mu             sync.Mutex
	subscribed     []string
	unsubscribed   []string
	subscribeErr   error
	unsubscribeErr error
}

func (f *fakePubSub) Subscribe(_ context.Context, channels ...string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.subscribed = append(f.subscribed, channels...)
	return f.subscribeErr
}

func (f *fakePubSub) Unsubscribe(_ context.Context, channels ...string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.unsubscribed = append(f.unsubscribed, channels...)
	return f.unsubscribeErr
}

func (f *fakePubSub) calls() (subscribed, unsubscribed []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.subscribed), slices.Clone(f.unsubscribed)
}

// newTestMux returns a mux whose messages are delivered by hand through
// m.deliver; closing the returned channel ends its run loop.
func newTestMux(t *testing.T, ps *fakePubSub) (*redisMux, chan *redis.Message) {
	t.Helper()
	in := make(chan *redis.Message)
	m := newRedisMux(ps, in)
	t.Cleanup(func() { close(in) })
	return m, in
}

func mustSubscribe(t *testing.T, m *redisMux, channel string) (<-chan []byte, func()) {
	t.Helper()
	out, release, err := m.subscribe(t.Context(), channel)
	if err != nil {
		t.Fatalf("subscribe %s: %v", channel, err)
	}
	return out, release
}

func receive(t *testing.T, out <-chan []byte) ([]byte, bool) {
	t.Helper()
	select {
	case payload, ok := <-out:
		return payload, ok
	case <-time.After(time.Second):
		t.Fatal("no frame and channel still open")
		return nil, false
	}
}

func assertClosed(t *testing.T, out <-chan []byte) {
	t.Helper()
	for {
		if _, ok := receive(t, out); !ok {
			return
		}
	}
}

func assertNoFrame(t *testing.T, out <-chan []byte) {
	t.Helper()
	select {
	case payload, ok := <-out:
		t.Fatalf("unexpected frame %q (open %v)", payload, ok)
	default:
	}
}

func TestRedisMuxRoutesFramesByChannel(t *testing.T) {
	ps := &fakePubSub{}
	m, in := newTestMux(t, ps)
	a, _ := mustSubscribe(t, m, "a")
	b, _ := mustSubscribe(t, m, "b")

	in <- &redis.Message{Channel: "a", Payload: "for a"}
	in <- &redis.Message{Channel: "nobody", Payload: "dropped"}
	in <- &redis.Message{Channel: "b", Payload: "for b"}

	if payload, _ := receive(t, a); string(payload) != "for a" {
		t.Fatalf("a got %q", payload)
	}
	if payload, _ := receive(t, b); string(payload) != "for b" {
		t.Fatalf("b got %q", payload)
	}
	assertNoFrame(t, a)
	if subscribed, _ := ps.calls(); !slices.Equal(subscribed, []string{"a", "b"}) {
		t.Fatalf("SUBSCRIBE calls = %v", subscribed)
	}
}

func TestRedisMuxReleaseUnsubscribesOnce(t *testing.T) {
	ps := &fakePubSub{}
	m, _ := newTestMux(t, ps)
	out, release := mustSubscribe(t, m, "a")

	release()
	release()

	assertClosed(t, out)
	if _, unsubscribed := ps.calls(); !slices.Equal(unsubscribed, []string{"a"}) {
		t.Fatalf("UNSUBSCRIBE calls = %v, want exactly one for a", unsubscribed)
	}
	m.deliver("a", []byte("late"))
}

func TestRedisMuxResubscribeReplacesEarlierSubscription(t *testing.T) {
	ps := &fakePubSub{}
	m, _ := newTestMux(t, ps)
	first, releaseFirst := mustSubscribe(t, m, "a")
	second, _ := mustSubscribe(t, m, "a")

	assertClosed(t, first)
	releaseFirst()
	m.deliver("a", []byte("still live"))

	if payload, ok := receive(t, second); !ok || string(payload) != "still live" {
		t.Fatalf("second got %q, open %v", payload, ok)
	}
	if _, unsubscribed := ps.calls(); len(unsubscribed) != 0 {
		t.Fatalf("stale release sent UNSUBSCRIBE %v under a live subscription", unsubscribed)
	}
}

func TestRedisMuxCountsFailedCommands(t *testing.T) {
	ps := &fakePubSub{subscribeErr: errors.New("write failed"), unsubscribeErr: errors.New("write failed")}
	m, _ := newTestMux(t, ps)
	before := parseCounterTotal(t, "router_redis_errors_total")

	out, release := mustSubscribe(t, m, "a")
	m.deliver("a", []byte("kept"))
	if payload, _ := receive(t, out); string(payload) != "kept" {
		t.Fatalf("subscription after a failed write got %q", payload)
	}
	release()

	if after := parseCounterTotal(t, "router_redis_errors_total"); after != before+2 {
		t.Fatalf("router_redis_errors_total = %d, want %d", after, before+2)
	}
}

func TestRedisMuxDropsChannelThatFallsBehind(t *testing.T) {
	ps := &fakePubSub{}
	m, _ := newTestMux(t, ps)
	slow, _ := mustSubscribe(t, m, "slow")
	other, _ := mustSubscribe(t, m, "other")

	for i := range _muxQueueSize + 1 {
		m.deliver("slow", []byte(strconv.Itoa(i)))
	}
	m.deliver("other", []byte("unaffected"))

	for i := range _muxQueueSize {
		if payload, ok := receive(t, slow); !ok || string(payload) != strconv.Itoa(i) {
			t.Fatalf("buffered frame %d = %q, open %v", i, payload, ok)
		}
	}
	assertClosed(t, slow)
	if payload, _ := receive(t, other); string(payload) != "unaffected" {
		t.Fatalf("other got %q", payload)
	}
	if _, unsubscribed := ps.calls(); !slices.Equal(unsubscribed, []string{"slow"}) {
		t.Fatalf("UNSUBSCRIBE calls = %v", unsubscribed)
	}
}

func TestRedisMuxClosesEverythingWhenConnectionCloses(t *testing.T) {
	in := make(chan *redis.Message)
	m := newRedisMux(&fakePubSub{}, in)
	a, _ := mustSubscribe(t, m, "a")
	b, _ := mustSubscribe(t, m, "b")

	close(in)

	assertClosed(t, a)
	assertClosed(t, b)
	if _, _, err := m.subscribe(t.Context(), "c"); !errors.Is(err, errLiveSourceClosed) {
		t.Fatalf("subscribe after close = %v, want %v", err, errLiveSourceClosed)
	}
}

// Every live channel must ride one Redis connection; a connection per channel
// is what this source exists to avoid.
func TestRedisLiveSourceSharesOneConnection(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	name := "livestream-mux-" + strconv.Itoa(os.Getpid())
	rc := redis.NewClient(&redis.Options{Addr: addr, ClientName: name})
	t.Cleanup(func() { _ = rc.Close() })
	src := NewRedisLiveSource(rc)
	prefix := "quality:livestream:" + name + ":"
	for _, channel := range []string{"a", "b", "c"} {
		_, release, err := src.Subscribe(ctx, prefix+channel)
		if err != nil {
			t.Fatal(err)
		}
		defer release()
		awaitRedisSubscription(t, ctx, rc, prefix+channel)
	}
	clients, err := rc.Do(ctx, "CLIENT", "LIST", "TYPE", "pubsub").Text()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(clients, "name="+name+" "); got != 1 {
		t.Fatalf("pub/sub connections named %s = %d, want 1\n%s", name, got, clients)
	}
}
