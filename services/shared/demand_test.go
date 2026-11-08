package shared

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// scriptedDemandRedis answers SetNX and ExpireGT from scripted results so every
// branch of the max-TTL write runs without a server.
type scriptedDemandRedis struct {
	redis.Cmdable
	setNX    []*redis.BoolCmd
	expireGT *redis.BoolCmd
	calls    []string
}

func (r *scriptedDemandRedis) SetNX(_ context.Context, key string, value any, ttl time.Duration) *redis.BoolCmd {
	r.calls = append(r.calls, "setnx "+key+" "+value.(string)+" "+ttl.String())
	next := r.setNX[0]
	r.setNX = r.setNX[1:]
	return next
}

func (r *scriptedDemandRedis) ExpireGT(_ context.Context, key string, ttl time.Duration) *redis.BoolCmd {
	r.calls = append(r.calls, "expiregt "+key+" "+ttl.String())
	return r.expireGT
}

func TestTouchLiveDemandFollowsMaxTTLSteps(t *testing.T) {
	failure := errors.New("redis down")
	ok := func(v bool) *redis.BoolCmd { return redis.NewBoolResult(v, nil) }
	failed := redis.NewBoolResult(false, failure)
	for _, tc := range []struct {
		name     string
		setNX    []*redis.BoolCmd
		expireGT *redis.BoolCmd
		created  bool
		err      bool
		calls    int
	}{
		{name: "new key", setNX: []*redis.BoolCmd{ok(true)}, created: true, calls: 1},
		{name: "claim fails", setNX: []*redis.BoolCmd{failed}, err: true, calls: 1},
		{name: "longer ttl extends", setNX: []*redis.BoolCmd{ok(false)}, expireGT: ok(true), calls: 2},
		{name: "extend fails", setNX: []*redis.BoolCmd{ok(false)}, expireGT: failed, err: true, calls: 2},
		{name: "shorter ttl keeps", setNX: []*redis.BoolCmd{ok(false), ok(false)}, expireGT: ok(false), calls: 3},
		{name: "expired in between", setNX: []*redis.BoolCmd{ok(false), ok(true)}, expireGT: ok(false), created: true, calls: 3},
		{name: "reclaim fails", setNX: []*redis.BoolCmd{ok(false), failed}, expireGT: ok(false), err: true, calls: 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rc := &scriptedDemandRedis{setNX: tc.setNX, expireGT: tc.expireGT}
			created, err := TouchLiveDemand(t.Context(), rc, "live:demand:bus_eta:Tainan", time.Minute)
			if created != tc.created || (err != nil) != tc.err || len(rc.calls) != tc.calls {
				t.Fatalf("created=%v err=%v calls=%v", created, err, rc.calls)
			}
			if tc.err && !errors.Is(err, failure) {
				t.Fatalf("err=%v lost its cause", err)
			}
			if rc.calls[0] != "setnx live:demand:bus_eta:Tainan 1 1m0s" {
				t.Fatalf("first call=%q", rc.calls[0])
			}
		})
	}
}

func TestTouchLiveDemandNeverShortensATTLOnRedis(t *testing.T) {
	addr := os.Getenv("REDIS_ADDR")
	if addr == "" {
		t.Skip("REDIS_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	key := LiveDemandKey("bus_eta", t.Name())
	t.Cleanup(func() { rc.Del(context.Background(), key) })
	rc.Del(t.Context(), key)

	steps := []struct {
		ttl     time.Duration
		created bool
		atLeast time.Duration
	}{
		{ttl: time.Hour, created: true, atLeast: 59 * time.Minute},
		{ttl: 10 * time.Minute, atLeast: 59 * time.Minute},
		{ttl: 2 * time.Hour, atLeast: 119 * time.Minute},
	}
	for i, step := range steps {
		created, err := TouchLiveDemand(t.Context(), rc, key, step.ttl)
		if err != nil || created != step.created {
			t.Fatalf("step %d: created=%v err=%v", i, created, err)
		}
		if ttl := rc.TTL(t.Context(), key).Val(); ttl < step.atLeast {
			t.Fatalf("step %d: ttl=%v, want at least %v", i, ttl, step.atLeast)
		}
	}
	if got := rc.Get(t.Context(), key).Val(); got != "1" {
		t.Fatalf("value=%q", got)
	}
}
