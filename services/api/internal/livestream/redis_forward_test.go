package livestream

import (
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestRedisForwarderStopsWhenBlockedSubscriberCloses(t *testing.T) {
	done := make(chan struct{})
	in := make(chan *redis.Message)
	out := make(chan []byte)
	stopped := make(chan struct{})
	go func() {
		forwardRedisSubscription(done, in, out)
		close(stopped)
	}()
	in <- &redis.Message{Payload: "waiting frame"}
	// The upstream handoff completes before cancellation, while the
	// downstream has no receiver and must be released by closing done.
	close(done)
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("Redis forwarder retained a closed subscriber")
	}
}

func TestRedisBlockedDeliveryHonorsCancellation(t *testing.T) {
	done := make(chan struct{})
	close(done)
	if forwardRedisMessage(done, &redis.Message{Payload: "undelivered"}, make(chan []byte)) {
		t.Fatal("closed subscriber accepted a frame")
	}
}

func TestRedisForwarderStopsWhenUpstreamCloses(t *testing.T) {
	in := make(chan *redis.Message)
	close(in)
	forwardRedisSubscription(make(chan struct{}), in, make(chan []byte))
}
