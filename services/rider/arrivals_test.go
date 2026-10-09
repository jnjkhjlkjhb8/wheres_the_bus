package main

import (
	"context"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/redis/go-redis/v9"
)

type recordingHandler struct {
	mu      sync.Mutex
	batches [][]riderevent.ArrivalEvent
	fail    bool
}

func (h *recordingHandler) Arrivals(_ context.Context, events []riderevent.ArrivalEvent) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.fail {
		return errors.New("push backend down")
	}
	h.batches = append(h.batches, events)
	return nil
}

func testRedis(t *testing.T) *redis.Client {
	t.Helper()
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	// Only this package's stream: a FlushDB would race other packages' tests.
	if err := rc.Del(context.Background(), riderevent.StreamKey).Err(); err != nil {
		t.Fatalf("reset stream: %v", err)
	}
	t.Cleanup(func() { _ = rc.Del(context.Background(), riderevent.StreamKey).Err() })
	return rc
}

func pendingCount(t *testing.T, rc *redis.Client) int64 {
	t.Helper()
	p, err := rc.XPending(context.Background(), riderevent.StreamKey, riderevent.Group).Result()
	if err != nil {
		t.Fatalf("XPENDING: %v", err)
	}
	return p.Count
}

func TestArrivalConsumerDispatchesAcksAndDropsStale(t *testing.T) {
	rc := testRedis(t)
	ctx := context.Background()
	h := &recordingHandler{}
	c := newArrivalConsumer(rc, h)
	if err := c.ensureGroup(ctx); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	fresh := []riderevent.ArrivalEvent{{RouteType: "bus", RouteKey: "R1", StopKey: "S1", ETASeconds: 60}}
	if err := (riderevent.Publisher{RC: rc, Now: func() time.Time { return now }}).Arrivals(ctx, fresh); err != nil {
		t.Fatal(err)
	}
	stale := []riderevent.ArrivalEvent{{RouteType: "bus", RouteKey: "R2"}}
	if err := (riderevent.Publisher{RC: rc, Now: func() time.Time { return now.Add(-_arrivalMaxAge - time.Second) }}).Arrivals(ctx, stale); err != nil {
		t.Fatal(err)
	}

	msgs := readNew(t, rc, c)
	c.handle(ctx, msgs)

	if len(h.batches) != 1 || h.batches[0][0].RouteKey != "R1" {
		t.Fatalf("dispatched = %+v, want only the fresh batch", h.batches)
	}
	if n := pendingCount(t, rc); n != 0 {
		t.Fatalf("pending = %d, want both entries acknowledged", n)
	}
}

func TestArrivalConsumerLeavesFailedDispatchPending(t *testing.T) {
	rc := testRedis(t)
	ctx := context.Background()
	h := &recordingHandler{fail: true}
	c := newArrivalConsumer(rc, h)
	if err := c.ensureGroup(ctx); err != nil {
		t.Fatal(err)
	}
	if err := (riderevent.Publisher{RC: rc}).Arrivals(ctx, []riderevent.ArrivalEvent{{RouteKey: "R1"}}); err != nil {
		t.Fatal(err)
	}
	c.handle(ctx, readNew(t, rc, c))
	if n := pendingCount(t, rc); n != 1 {
		t.Fatalf("pending = %d, want the failed entry left for reclaim", n)
	}
}

func TestEnsureGroupIsIdempotent(t *testing.T) {
	rc := testRedis(t)
	c := newArrivalConsumer(rc, &recordingHandler{})
	for range 2 {
		if err := c.ensureGroup(context.Background()); err != nil {
			t.Fatalf("ensureGroup: %v", err)
		}
	}
}

func readNew(t *testing.T, rc *redis.Client, c *arrivalConsumer) []redis.XMessage {
	t.Helper()
	streams, err := rc.XReadGroup(context.Background(), &redis.XReadGroupArgs{
		Group: riderevent.Group, Consumer: c.consumer,
		Streams: []string{riderevent.StreamKey, ">"}, Count: 10, Block: -1,
	}).Result()
	if err != nil {
		t.Fatalf("XREADGROUP: %v", err)
	}
	return streams[0].Messages
}
