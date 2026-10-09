package bus

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

var errBusPostCommitCache = errors.New("bus snapshot post-commit cache invalidation failed")

func Load(ctx context.Context, src pipeline.LoadSource, db *pgxpool.Pool, rc *redis.Client, city string) error {
	zap.S().Infow("city start", "component", "load", "action", "bus", "event", "city_start", "city", city)
	snapshot, err := readBusCitySnapshot(ctx, src, city)
	if err != nil {
		return _oops.With("city", city).Wrapf(err, "load bus city: snapshot")
	}
	if err := persistBusCitySnapshot(ctx, pgBusTxBeginner{db: db}, snapshot, func() error {
		return invalidateBusStaticAfterCommit(ctx, rc, city)
	}); err != nil {
		if !errors.Is(err, errBusPostCommitCache) {
			return _oops.With("city", city).Wrapf(err, "load bus city: target")
		}
		// PostgreSQL is already committed. Return the post-commit failure so the
		// daily retry repeats the idempotent write and repairs the generation.
		return _oops.With("city", city).Wrapf(err, "load bus city: committed; invalidate cache")
	}
	zap.S().Infow("city complete",
		"component", "load",
		"action", "bus",
		"event", "city_complete",
		"city", city,
		"subroute_count", len(snapshot.subroutes),
	)
	return nil
}

func persistBusCitySnapshot(
	ctx context.Context,
	db busTxBeginner,
	snapshot *busCitySnapshot,
	invalidate func() error,
) error {
	if err := writeBusCitySnapshot(ctx, db, snapshot); err != nil {
		return err
	}
	if invalidate == nil {
		return _oops.Wrapf(errBusPostCommitCache, "nil invalidator")
	}
	if err := invalidate(); err != nil {
		return errors.Join(errBusPostCommitCache, err)
	}
	return nil
}

func invalidateBusStaticAfterCommit(ctx context.Context, rc *redis.Client, city string) error {
	prefix := busmodel.CityPrefix[city]
	predict.InvalidateStaticMapCity(prefix)
	if rc == nil {
		return errors.New("redis client is nil")
	}
	generation, incrementErr := rc.Incr(ctx, shared.BusStaticGenerationKey(city)).Result()
	publishErr := rc.Publish(ctx, shared.BusStaticGenerationChannel(city), generation).Err()
	return errors.Join(incrementErr, publishErr)
}
