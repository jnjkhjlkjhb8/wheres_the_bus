package riderevent

import (
	"context"
	"errors"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func watchTestRedis(t *testing.T) *redis.Client {
	t.Helper()
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 10})
	reset := func() { _ = rc.Del(context.Background(), WatchKey, StreamKey).Err() }
	reset()
	t.Cleanup(func() {
		reset()
		_ = rc.Close()
	})
	return rc
}

func TestWatchMemberJoinsTheMatchFields(t *testing.T) {
	if got := WatchMember("bus", "TPE1", "S1", "0"); got != "bus|TPE1|S1|0" {
		t.Fatalf("WatchMember = %q", got)
	}
}

func TestStoreWatchReplacesTheSet(t *testing.T) {
	rc := watchTestRedis(t)
	ctx := t.Context()

	if err := StoreWatch(ctx, rc, []string{"a", "b"}); err != nil {
		t.Fatal(err)
	}
	if err := StoreWatch(ctx, rc, []string{"c"}); err != nil {
		t.Fatal(err)
	}
	members, err := rc.SMembers(ctx, WatchKey).Result()
	if err != nil || !slices.Equal(members, []string{"c"}) {
		t.Fatalf("members = %v, err %v; want only the latest list", members, err)
	}
	if ttl := rc.TTL(ctx, WatchKey).Val(); ttl <= WatchTTL-time.Minute || ttl > WatchTTL {
		t.Fatalf("TTL = %v, want about %v", ttl, WatchTTL)
	}

	if err := StoreWatch(ctx, rc, nil); err != nil {
		t.Fatal(err)
	}
	if n := rc.Exists(ctx, WatchKey).Val(); n != 0 {
		t.Fatal("an empty list left the old set in place")
	}
}

func TestWatchedPublishesOnlyWatchedArrivals(t *testing.T) {
	rc := watchTestRedis(t)
	ctx := t.Context()
	watched := ArrivalEvent{RouteType: "bus", RouteKey: "R1", StopKey: "S1", Direction: "0", ETASeconds: 60}
	otherDirection := watched
	otherDirection.Direction = "1"
	otherStop := watched
	otherStop.StopKey = "S2"
	if err := StoreWatch(ctx, rc, []string{WatchMember("bus", "R1", "S1", "0")}); err != nil {
		t.Fatal(err)
	}
	publisher := Watched{Publisher: Publisher{RC: rc}}

	if err := publisher.Arrivals(ctx, []ArrivalEvent{otherDirection, watched, otherStop}); err != nil {
		t.Fatal(err)
	}
	if err := StoreWatch(ctx, rc, nil); err != nil {
		t.Fatal(err)
	}
	if err := publisher.Arrivals(ctx, []ArrivalEvent{watched}); err != nil {
		t.Fatal(err)
	}

	entries, err := rc.XRange(ctx, StreamKey, "-", "+").Result()
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries = %d, err %v; want one batch, none once nothing is watched", len(entries), err)
	}
	events, _, err := Decode(entries[0])
	if err != nil || !slices.Equal(events, []ArrivalEvent{watched}) {
		t.Fatalf("published %+v, err %v; want only the watched arrival", events, err)
	}
}

func TestWatchedReportsAnUnreadableWatch(t *testing.T) {
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	err := Watched{Publisher: Publisher{RC: rc}}.Arrivals(context.Background(), []ArrivalEvent{{RouteKey: "R1"}})
	if !errors.Is(err, redis.ErrClosed) {
		t.Fatalf("err = %v, want the Redis cause", err)
	}
	if err := StoreWatch(context.Background(), rc, []string{"a"}); !errors.Is(err, redis.ErrClosed) {
		t.Fatalf("StoreWatch err = %v, want the Redis cause", err)
	}
}
