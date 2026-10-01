package livestream

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type hubSource struct {
	mu            sync.Mutex
	channels      map[string]chan []byte
	subscriptions map[string]int
	cancellations map[string]int
}

func (s *hubSource) Touch(context.Context, string, time.Duration) {}

func newHubSource() *hubSource {
	return &hubSource{
		channels:      map[string]chan []byte{},
		subscriptions: map[string]int{},
		cancellations: map[string]int{},
	}
}

func (s *hubSource) Get(context.Context, string) ([]byte, bool) {
	return nil, false
}

func (s *hubSource) ScanKeys(context.Context, string) []string {
	return nil
}

func (s *hubSource) Subscribe(_ context.Context, channel string) (<-chan []byte, func(), error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.subscriptions[channel]++
	ch := s.channels[channel]
	if ch == nil {
		ch = make(chan []byte, 16)
		s.channels[channel] = ch
	}
	return ch, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.cancellations[channel]++
	}, nil
}

func (s *hubSource) publish(channel string, payload []byte) {
	s.mu.Lock()
	ch := s.channels[channel]
	s.mu.Unlock()
	ch <- payload
}

func (s *hubSource) close(channel string) {
	s.mu.Lock()
	ch := s.channels[channel]
	s.mu.Unlock()
	close(ch)
}

func (s *hubSource) subscriptionCount(channel string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.subscriptions[channel]
}

func (s *hubSource) cancellationCount(channel string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cancellations[channel]
}

func TestLiveHubSharesOneUpstreamSubscription(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHub(src, 10)

	first, closeFirst, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	second, closeSecond, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}

	src.publish("route:1", []byte("eta"))
	if got := string(<-first); got != "eta" {
		t.Fatalf("first frame = %q", got)
	}
	if got := string(<-second); got != "eta" {
		t.Fatalf("second frame = %q", got)
	}
	if got := src.subscriptionCount("route:1"); got != 1 {
		t.Fatalf("upstream subscriptions = %d, want 1", got)
	}

	closeFirst()
	closeSecond()
}

func TestLiveHubOrderedDeliveryForHealthySubscriber(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHub(src, 10)

	stream, closeStream, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	defer closeStream()

	want := []string{"frame-0", "frame-1", "frame-2", "frame-3", "frame-4"}
	for _, frame := range want {
		src.publish("route:1", []byte(frame))
	}

	for i, expect := range want {
		select {
		case got := <-stream:
			if string(got) != expect {
				t.Fatalf("frame[%d] = %q, want %q", i, got, expect)
			}
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for frame[%d] = %q", i, expect)
		}
	}
}

// TestLiveHubEvictsSlowSubscriberOnOverflow asserts that once a subscriber's
// bounded queue is full, the hub evicts and closes that subscriber instead
// of silently replacing the oldest unread frame.
func TestLiveHubEvictsSlowSubscriberOnOverflow(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHubWithQueueSize(src, 10, 4)

	stream, closeStream, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	defer closeStream()

	for range 6 {
		src.publish("route:1", []byte("frame"))
	}

	deadline := time.Now().Add(time.Second)
	for hub.Stats().EvictedSubscribers == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := hub.Stats().EvictedSubscribers; got != 1 {
		t.Fatalf("EvictedSubscribers = %d, want 1", got)
	}

	deadline = time.Now().Add(time.Second)
	for {
		select {
		case _, ok := <-stream:
			if !ok {
				return
			}
		case <-time.After(time.Second):
			t.Fatal("stream was not closed after overflow eviction")
		}
		if time.Now().After(deadline) {
			t.Fatal("stream was not closed after overflow eviction")
		}
	}
}

// TestLiveHubOverflowEvictsOnlyTheSlowSubscriber asserts that overflow on
// one subscriber's queue does not disturb a healthy subscriber reading the
// same channel: ordered delivery keeps working for it.
func TestLiveHubOverflowEvictsOnlyTheSlowSubscriber(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHubWithQueueSize(src, 10, 4)

	slow, closeSlow, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	defer closeSlow()
	healthy, closeHealthy, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	defer closeHealthy()

	// The healthy subscriber drains after every publish so its own queue
	// never approaches the bound; only the never-read slow subscriber's
	// queue fills and overflows.
	var received []string
	for i := range 6 {
		src.publish("route:1", []byte(fmt.Sprintf("frame-%d", i)))
		select {
		case frame := <-healthy:
			received = append(received, string(frame))
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for frame %d on healthy subscriber", i)
		}
	}

	if len(received) != 6 {
		t.Fatalf("healthy subscriber received %d frames, want 6: %v", len(received), received)
	}
	for i, frame := range received {
		if want := fmt.Sprintf("frame-%d", i); frame != want {
			t.Fatalf("received[%d] = %q, want %q", i, frame, want)
		}
	}

	deadline := time.Now().Add(time.Second)
	for hub.Stats().EvictedSubscribers == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := hub.Stats().EvictedSubscribers; got != 1 {
		t.Fatalf("EvictedSubscribers = %d, want 1", got)
	}
	// Draining what remained buffered, the channel must still end up closed:
	// a slow subscriber never gets a permanently-stuck stream.
	drained := make(chan struct{})
	go func() {
		defer close(drained)
		for range slow {
		}
	}()
	select {
	case <-drained:
	case <-time.After(time.Second):
		t.Fatal("slow subscriber stream should have been closed by eviction")
	}
}

func TestLiveHubClosesUpstreamAfterLastSubscriber(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHub(src, 10)

	_, closeStream, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	closeStream()
	if got := src.cancellationCount("route:1"); got != 1 {
		t.Fatalf("upstream cancellations = %d, want 1", got)
	}
}

func TestLiveHubClosesUpstreamAfterSourceDisconnect(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHub(src, 10)

	stream, closeStream, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	defer closeStream()

	src.close("route:1")
	if _, ok := <-stream; ok {
		t.Fatal("stream remained open after upstream disconnect")
	}
	deadline := time.Now().Add(time.Second)
	for src.cancellationCount("route:1") == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := src.cancellationCount("route:1"); got != 1 {
		t.Fatalf("upstream cancellations = %d, want 1", got)
	}
}

func TestLiveHubUnsubscribeClearsCloseReasonAfterEviction(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHubWithQueueSize(src, 10, 1)

	stream, closeStream, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}

	for range 3 {
		src.publish("route:1", []byte("frame"))
	}
	deadline := time.Now().Add(time.Second)
	for hub.Stats().EvictedSubscribers == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := hub.Stats().EvictedSubscribers; got != 1 {
		t.Fatalf("EvictedSubscribers = %d, want 1", got)
	}
	// Drain the channel so it is confirmed closed before we exercise the
	// caller's own cleanup path.
	for range stream {
	}

	closeStream()

	hub.mu.Lock()
	leaked := len(hub.closeReasons)
	hub.mu.Unlock()
	if leaked != 0 {
		t.Fatalf("closeReasons leaked %d entries after unsubscribe following eviction", leaked)
	}
}

func TestLiveHubRejectsStreamAboveLimit(t *testing.T) {
	src := newHubSource()
	hub := NewLiveHub(src, 1)

	_, closeStream, err := hub.Subscribe(context.Background(), "route:1")
	if err != nil {
		t.Fatal(err)
	}
	defer closeStream()

	_, _, err = hub.Subscribe(context.Background(), "route:2")
	if got := status.Code(err); got != codes.ResourceExhausted {
		t.Fatalf("status code = %s, want %s", got, codes.ResourceExhausted)
	}
	if got := src.subscriptionCount("route:2"); got != 0 {
		t.Fatalf("upstream subscriptions = %d, want 0", got)
	}
}
