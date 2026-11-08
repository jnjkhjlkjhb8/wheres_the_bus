package firebase

import (
	"context"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
)

// TestRedisDemandNeverShortensAReminderClaim: one reminder's shorter claim must
// not cut another's longer one, or the city stops being fetched before the
// longer reminder fires.
func TestRedisDemandNeverShortensAReminderClaim(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	ctx := context.Background()
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 15})
	key := shared.LiveDemandKey("bus_eta", t.Name()+strconv.Itoa(os.Getpid()))
	t.Cleanup(func() { _ = rc.Del(ctx, key).Err(); _ = rc.Close() })
	demand := RedisDemand{RC: rc}
	demand.Touch(ctx, key, 2*time.Hour)
	demand.Touch(ctx, key, 10*time.Minute)
	if ttl := rc.TTL(ctx, key).Val(); ttl < 119*time.Minute {
		t.Fatalf("demand TTL=%v, want the two hours kept", ttl)
	}
	demand.Touch(ctx, key, 3*time.Hour)
	if ttl := rc.TTL(ctx, key).Val(); ttl < 179*time.Minute {
		t.Fatalf("demand TTL=%v, want it extended to three hours", ttl)
	}
	closed := RedisDemand{RC: redis.NewClient(&redis.Options{Addr: addr})}
	_ = closed.RC.Close()
	closed.Touch(ctx, key, time.Minute)
}
