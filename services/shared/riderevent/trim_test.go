package riderevent

import (
	"context"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// The stream must drop entries older than MaxAge on every publish: one entry
// is a whole city's batch, so keeping them by count alone outgrew Redis.
func TestArrivalPublisherTrimsEntriesPastMaxAge(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 10})
	t.Cleanup(func() {
		_ = rc.Del(context.Background(), StreamKey).Err()
		_ = rc.Close()
	})
	if err := rc.Del(ctx, StreamKey).Err(); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for _, age := range []time.Duration{MaxAge + time.Second, MaxAge - 10*time.Second} {
		id := strconv.FormatInt(now.Add(-age).UnixMilli(), 10) + "-0"
		if err := rc.XAdd(ctx, &redis.XAddArgs{Stream: StreamKey, ID: id, Values: []any{"k", "v"}}).Err(); err != nil {
			t.Fatal(err)
		}
	}

	publisher := Publisher{RC: rc, Now: func() time.Time { return now }}
	if err := publisher.Arrivals(ctx, []ArrivalEvent{{RouteType: "bus", RouteKey: "R1"}}); err != nil {
		t.Fatal(err)
	}

	entries, err := rc.XRange(ctx, StreamKey, "-", "+").Result()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("entries = %d, want the in-age entry and the new one", len(entries))
	}
	events, at, err := Decode(entries[1])
	if err != nil || len(events) != 1 || events[0].RouteKey != "R1" || !at.Equal(now.Truncate(time.Millisecond)) {
		t.Fatalf("published entry = %+v at %v, err %v", events, at, err)
	}
}
