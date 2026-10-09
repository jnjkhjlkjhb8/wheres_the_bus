package main

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bike"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/mrt"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/rail"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

func liveRegistry(db *pgxpool.Pool, notifier bus.ArrivalNotifier) []pipeline.LiveSpec {
	bikeOwnedKey := func(fetchName string) string {
		return shared.LiveOwnedKeysKey("bike", strings.TrimPrefix(fetchName, "bike_availability"))
	}
	traPatterns := func(string) []pipeline.TTLPattern {
		return []pipeline.TTLPattern{
			{Pattern: shared.TraDelayAllKey, TTL: pipeline.TraLiveTTL},
			{Pattern: shared.TraDelayHashKey, TTL: pipeline.TraLiveTTL},
			{Pattern: shared.TraDelayStationKey, TTL: pipeline.TraLiveTTL},
			{Pattern: shared.TraDelayTrainChannel("*"), TTL: pipeline.TraLiveTTL},
		}
	}
	thsrSeatsPatterns := func(string) []pipeline.TTLPattern {
		// Re-arm today's per-train seat keys on a 304; the date is resolved when the
		// 304 fires so the pattern always targets the current service day.
		return []pipeline.TTLPattern{{Pattern: shared.ThsrSeatsPattern(time.Now().In(pipeline.Taipei).Format(time.DateOnly)), TTL: pipeline.ThsrSeatsLiveTTL}}
	}
	return []pipeline.LiveSpec{
		{Key: "bike", Cadence: "@every 30s", OwnedKey: bikeOwnedKey, OwnedTTL: pipeline.BikeLiveTTL,
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return bike.Eta(ctx, fetch, sink, db)
			}},
		{Key: "bus", Cadence: "@every 30s", TTLPatterns: nil,
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return bus.Eta(ctx, fetch, sink, db, notifier)
			}},
		{Key: "bus_fast", Cadence: "@every 20s", TTLPatterns: nil,
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return bus.EtaFast(ctx, fetch, sink, db, notifier)
			}},
		{Key: "mrt", Cadence: "@every 15s",
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return mrt.TrtcEta(ctx, sink, db)
			}},
		{Key: "tra", Cadence: "@every 2m", TTLPatterns: traPatterns, Run: rail.TraEta},
		{Key: "thsr_seats", Cadence: "@every 10m", TTLPatterns: thsrSeatsPatterns, Run: rail.ThsrAvailableSeats},
	}
}

const _liveJobTimeout = 25 * time.Second

func liveTickDeadline(cadence string) time.Duration {
	d, err := time.ParseDuration(strings.TrimPrefix(cadence, "@every "))
	if err != nil || d <= 0 {
		return _liveJobTimeout
	}
	return d - d/6
}

func registerLiveCrons(r *cron.Cron, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool, notifier bus.ArrivalNotifier) {
	src := pipeline.NewRESTLiveSource(tdx)
	sink := pipeline.NewRedisLiveSink(rc)
	specs := liveRegistry(db, notifier)

	// Group specs by cadence, keeping registry order within each group so the
	// 30s tick still runs bike before bus.
	order := []string{}
	byCadence := map[string][]pipeline.LiveSpec{}
	for _, s := range specs {
		if _, seen := byCadence[s.Cadence]; !seen {
			order = append(order, s.Cadence)
		}
		byCadence[s.Cadence] = append(byCadence[s.Cadence], s)
	}

	for _, cadence := range order {
		group := byCadence[cadence]
		deadline := liveTickDeadline(cadence)
		_, _ = addStaticCron(r, cadence, func() {
			zap.S().Infow("start",
				"component", "live",
				"action", "tick",
				"event", "start",
				"cadence", cadence,
				"jobs", len(group),
				"deadline", deadline,
			)
			pipeline.WithTimeout(deadline, func(ctx context.Context) {
				for _, spec := range group {
					if ctx.Err() != nil {
						zap.S().Warnw("overrun",
							"component", "live",
							"action", "tick",
							"event", "overrun",
							"cadence", cadence,
							"deadline", deadline,
							"job", spec.Key,
						)
						break
					}
					pipeline.RunLiveSpec(ctx, src, sink, spec)
				}
			})
			zap.S().Infow("end", "component", "live", "action", "tick", "event", "end", "cadence", cadence)
		})
	}

}
