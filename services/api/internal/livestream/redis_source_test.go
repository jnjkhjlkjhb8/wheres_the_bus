package livestream

import (
	"context"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestRedisLiveSourceLifecycle(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	src := NewRedisLiveSource(rc)
	key := "quality:livestream:" + t.Name() + ":" + strconv.Itoa(os.Getpid())
	t.Cleanup(func() { _ = rc.Del(context.Background(), key, key+":demand").Err() })
	if _, ok := src.Get(ctx, key); ok {
		t.Fatal("missing key returned a payload")
	}
	if err := rc.Set(ctx, key, "seed", time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	if payload, ok := src.Get(ctx, key); !ok || string(payload) != "seed" {
		t.Fatalf("cached payload = %q, found %v", payload, ok)
	}
	keys := src.ScanKeys(ctx, key)
	if len(keys) != 1 || keys[0] != key {
		t.Fatalf("scan keys = %v, want [%s]", keys, key)
	}
	src.Touch(ctx, key+":demand", time.Minute)
	if value, err := rc.Get(ctx, key+":demand").Result(); err != nil || value != "1" {
		t.Fatalf("demand value = %q, err %v", value, err)
	}
	if ttl, err := rc.TTL(ctx, key+":demand").Result(); err != nil || ttl <= 0 || ttl > time.Minute {
		t.Fatalf("demand TTL = %v, err %v", ttl, err)
	}
	ch, closeSub, err := src.Subscribe(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	defer closeSub()
	awaitRedisSubscription(t, ctx, rc, key)
	if err := rc.Publish(ctx, key, "live").Err(); err != nil {
		t.Fatal(err)
	}
	select {
	case value, ok := <-ch:
		if !ok || string(value) != "live" {
			t.Fatalf("live payload = %q, open %v", value, ok)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}

func awaitRedisSubscription(t *testing.T, ctx context.Context, rc *redis.Client, channel string) {
	t.Helper()
	for {
		counts, err := rc.PubSubNumSub(ctx, channel).Result()
		if err != nil {
			t.Fatal(err)
		}
		if counts[channel] == 1 {
			return
		}
		select {
		case <-time.After(time.Millisecond):
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
}
