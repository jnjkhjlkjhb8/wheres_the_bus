package shared

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

// TouchLiveDemand keeps a live demand key alive for at least ttl and never
// shortens it: a short stream claim must not cut a reminder's longer one. It
// reports whether this call created the key, which is the moment a cold
// partition becomes watched.
func TouchLiveDemand(ctx context.Context, rc redis.Cmdable, key string, ttl time.Duration) (bool, error) {
	created, err := rc.SetNX(ctx, key, "1", ttl).Result()
	if err != nil {
		return false, _oops.With("key", key).Wrapf(err, "claim live demand")
	}
	if created {
		return true, nil
	}
	return extendLiveDemand(ctx, rc, key, ttl)
}

func extendLiveDemand(ctx context.Context, rc redis.Cmdable, key string, ttl time.Duration) (bool, error) {
	extended, err := rc.ExpireGT(ctx, key, ttl).Result()
	if err != nil {
		return false, _oops.With("key", key).Wrapf(err, "extend live demand")
	}
	if extended {
		return false, nil
	}
	// EXPIRE GT also reports false when the key expired since SET NX saw it, so
	// claim it once more; on a key that still exists this is a no-op.
	created, err := rc.SetNX(ctx, key, "1", ttl).Result()
	if err != nil {
		return false, _oops.With("key", key).Wrapf(err, "reclaim live demand")
	}
	return created, nil
}
