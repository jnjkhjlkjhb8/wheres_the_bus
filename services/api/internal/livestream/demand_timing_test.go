package livestream

import (
	"context"
	"errors"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
)

type leasedDemandSource struct {
	*fakeLiveSource
	leases []time.Duration
}

func (s *leasedDemandSource) Touch(ctx context.Context, key string, ttl time.Duration) {
	s.leases = append(s.leases, ttl)
	s.fakeLiveSource.Touch(ctx, key, ttl)
}

func renewTick() <-chan time.Time {
	tick := make(chan time.Time, 1)
	tick <- time.Now()
	return tick
}

func TestDemandClaimAndRenewalKeepTenMinuteLease(t *testing.T) {
	src := &leasedDemandSource{fakeLiveSource: newFakeLiveSource()}
	stream := newLiveStream(t.Context(), src, LiveStreamSpec{DemandKey: "live:demand:bus_eta:Taipei"}, func([]byte) error { return nil })
	if err := stream.step(t.Context(), src.ch, renewTick()); err != nil {
		t.Fatal(err)
	}
	if len(src.leases) != 2 {
		t.Fatalf("demand leases = %v, want initial claim and renewal", src.leases)
	}
	for _, ttl := range src.leases {
		if ttl != 10*time.Minute {
			t.Fatalf("demand TTL = %v, want ten minutes", ttl)
		}
	}
	if _demandRefresh != 4*time.Minute {
		t.Fatalf("demand renewal interval = %v, want four minutes", _demandRefresh)
	}
}

// TestDemandRenewsOnTimerNotFrames: a quiet channel must still renew demand,
// and frames alone must not, or a partition whose data stops changing would
// lose its demand and never be fetched again.
func TestDemandRenewsOnTimerNotFrames(t *testing.T) {
	src := newFakeLiveSource()
	var sent []string
	stream := liveStream{source: src, spec: LiveStreamSpec{DemandKey: "demand:city"}, usable: func(b []byte) bool { return string(b) != "skip" },
		send: func(b []byte) error { sent = append(sent, string(b)); return nil }}
	src.ch <- []byte("frame")
	src.ch <- []byte("skip")
	for range 2 {
		if err := stream.step(t.Context(), src.ch, nil); err != nil {
			t.Fatal(err)
		}
	}
	if len(src.touches) != 0 || len(sent) != 1 || sent[0] != "frame" {
		t.Fatalf("frames touched %v and sent %v", src.touches, sent)
	}
	if err := stream.step(t.Context(), src.ch, renewTick()); err != nil {
		t.Fatal(err)
	}
	if len(src.touches) != 1 || src.touches[0] != "demand:city" {
		t.Fatalf("renewal touches = %v", src.touches)
	}
}

func TestDemandRenewalWithoutDemandKeyTouchesNothing(t *testing.T) {
	src := newFakeLiveSource()
	stream := liveStream{source: src}
	if err := stream.step(t.Context(), src.ch, renewTick()); err != nil {
		t.Fatal(err)
	}
	if len(src.touches) != 0 {
		t.Fatal("stream without a demand key renewed demand")
	}
}

func TestStepEndsOnCancelAndClose(t *testing.T) {
	src := newFakeLiveSource()
	stream := liveStream{source: src}
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	if err := stream.step(cancelled, nil, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled step = %v", err)
	}
	closed := make(chan []byte)
	close(closed)
	if err := stream.step(t.Context(), closed, nil); !errors.Is(err, errLiveSourceClosed) {
		t.Fatalf("closed step = %v", err)
	}
}

// TestRedisDemandTouchWakesOnceAndNeverShortens: only the write that creates
// the key wakes realtime, and a shorter claim leaves a longer TTL alone.
func TestRedisDemandTouchWakesOnceAndNeverShortens(t *testing.T) {
	addr := os.Getenv("REDIS_ADDR")
	if addr == "" {
		t.Skip("REDIS_ADDR not set")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	key := shared.LiveDemandKey("bus_eta", t.Name()+strconv.Itoa(os.Getpid()))
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err() })
	sub := rc.Subscribe(ctx, shared.LiveWakeChannel)
	t.Cleanup(func() { _ = sub.Close() })
	if _, err := sub.Receive(ctx); err != nil {
		t.Fatal(err)
	}
	src := NewRedisLiveSource(rc)
	src.Touch(ctx, key, time.Hour)
	src.Touch(ctx, key, time.Minute)
	if ttl := rc.TTL(ctx, key).Val(); ttl < 59*time.Minute {
		t.Fatalf("demand TTL = %v, want the hour kept", ttl)
	}
	wakes := 0
	for {
		msg, err := sub.ReceiveTimeout(ctx, 300*time.Millisecond)
		if err != nil {
			break
		}
		if m, ok := msg.(*redis.Message); ok && m.Payload == key {
			wakes++
		}
	}
	if wakes != 1 {
		t.Fatalf("wakes = %d, want 1", wakes)
	}
}

func TestRedisDemandWakeFailureIsCounted(t *testing.T) {
	unreachable := RedisLiveSource{rc: redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", DialTimeout: 200 * time.Millisecond})}
	t.Cleanup(func() { _ = unreachable.rc.Close() })
	before := parseCounterTotal(t, "router_redis_errors_total")
	unreachable.wake(t.Context(), "live:demand:bus_eta:Tainan")
	if after := parseCounterTotal(t, "router_redis_errors_total"); after != before+1 {
		t.Fatalf("router_redis_errors_total = %d, want %d", after, before+1)
	}
}
