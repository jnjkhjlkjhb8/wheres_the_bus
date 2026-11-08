package main

import (
	"context"
	"os"
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

func liveRegistry(db *pgxpool.Pool, notifier bus.ArrivalNotifier, guard *pipeline.LiveFetchGuard) []pipeline.LiveSpec {
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
				return bike.Eta(ctx, fetch, sink, db, guard)
			}},
		{Key: "bus", Cadence: "@every 30s", TTLPatterns: nil,
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return bus.Eta(ctx, fetch, sink, db, notifier, guard)
			}},
		{Key: "bus_fast", Cadence: "@every 20s", TTLPatterns: nil,
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return bus.EtaFast(ctx, fetch, sink, db, notifier)
			}},
		{Key: "mrt", Cadence: "@every 15s",
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return mrt.TrtcEta(ctx, sink, db)
			}},
		{Key: "tra", Cadence: "@every 2m", TTLPatterns: traPatterns,
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return rail.TraEta(ctx, fetch, sink, guard)
			}},
		{Key: "thsr_seats", Cadence: "@every 10m", TTLPatterns: thsrSeatsPatterns,
			Run: func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return rail.ThsrAvailableSeats(ctx, fetch, sink, guard)
			}},
	}
}

// _tdxLiveJobs are the live jobs whose only source is TDX REST. bus_fast
// (Data.taipei) and mrt (Metro Taipei API) are absent: they run without TDX.
var _tdxLiveJobs = map[string]struct{}{
	"bike":       {},
	"bus":        {},
	"tra":        {},
	"thsr_seats": {},
}

// _manualLiveJobs maps a `functions run <job>` name to its live spec key.
var _manualLiveJobs = map[string]string{"bikeeta": "bike", "traeta": "tra", "buseta": "bus"}

// tdxCredentialsSet follows the pipeline ingestor's convention: an empty TDX
// credential means TDX is off, not misconfigured.
func tdxCredentialsSet() bool {
	return os.Getenv("TDX_CLIENT_ID") != "" && os.Getenv("TDX_CLIENT_SECRET") != ""
}

func liveJobNeedsTDX(key string) bool {
	_, ok := _tdxLiveJobs[key]
	return ok
}

// runnableLiveSpecs drops the TDX-REST jobs when TDX is off, so they are never
// scheduled instead of failing on every tick.
func runnableLiveSpecs(specs []pipeline.LiveSpec, hasTDX bool) []pipeline.LiveSpec {
	if hasTDX {
		return specs
	}
	kept, skipped := splitTDXLiveSpecs(specs)
	zap.S().Infow("skip TDX live jobs", "component", "live", "action", "register", "event", "skip_tdx", "reason", "no_tdx_credentials", "jobs", skipped)
	return kept
}

func splitTDXLiveSpecs(specs []pipeline.LiveSpec) (kept []pipeline.LiveSpec, skipped []string) {
	for _, spec := range specs {
		if liveJobNeedsTDX(spec.Key) {
			skipped = append(skipped, spec.Key)
			continue
		}
		kept = append(kept, spec)
	}
	return kept, skipped
}

// manualLiveJob resolves a manual run to its live spec key. Every manual live
// job reads TDX, so without credentials it fails up front instead of running
// a job that can only error.
func manualLiveJob(job string) (string, error) {
	name, ok := _manualLiveJobs[job]
	if !ok {
		return "", _oops.With("args", job).Errorf("unknown job")
	}
	if !tdxCredentialsSet() {
		return "", _oops.With("job", job).Errorf("TDX credentials missing: set TDX_CLIENT_ID and TDX_CLIENT_SECRET")
	}
	return name, nil
}

const _liveJobTimeout = 25 * time.Second

func liveTickDeadline(cadence string) time.Duration {
	d, err := time.ParseDuration(strings.TrimPrefix(cadence, "@every "))
	if err != nil || d <= 0 {
		return _liveJobTimeout
	}
	return d - d/6
}

// registerLiveCrons schedules the live jobs and returns the waker for the same
// jobs, sharing one fetch guard so a wake and a tick fetch a partition once.
func registerLiveCrons(r *cron.Cron, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool, notifier bus.ArrivalNotifier) *liveWaker {
	src := pipeline.NewRESTLiveSource(tdx)
	sink := pipeline.NewRedisLiveSink(rc)
	guard := pipeline.NewLiveFetchGuard()
	specs := runnableLiveSpecs(liveRegistry(db, notifier, guard), tdxCredentialsSet())

	order, byCadence := groupLiveCadences(specs)

	for _, cadence := range order {
		group := byCadence[cadence]
		deadline := liveTickDeadline(cadence)
		_, _ = addStaticCron(r, cadence, func() { runLiveCadence(src, sink, cadence, group, deadline) })
	}
	return newLiveWaker(src, sink, specs, liveWakeTargets(db, notifier, guard))
}

func groupLiveCadences(specs []pipeline.LiveSpec) ([]string, map[string][]pipeline.LiveSpec) {
	// Retain registry order so the shared 30-second tick still runs bike before bus.
	order := []string{}
	byCadence := map[string][]pipeline.LiveSpec{}
	for _, spec := range specs {
		if _, seen := byCadence[spec.Cadence]; !seen {
			order = append(order, spec.Cadence)
		}
		byCadence[spec.Cadence] = append(byCadence[spec.Cadence], spec)
	}
	return order, byCadence
}

func runLiveCadence(src pipeline.LiveSource, sink pipeline.LiveSink, cadence string, group []pipeline.LiveSpec, deadline time.Duration) {
	zap.S().Infow("start", "component", "live", "action", "tick", "event", "start", "cadence", cadence, "jobs", len(group), "deadline", deadline)
	pipeline.WithTimeout(deadline, func(ctx context.Context) { runLiveCadenceJobs(ctx, src, sink, cadence, group, deadline) })
	zap.S().Infow("end", "component", "live", "action", "tick", "event", "end", "cadence", cadence)
}

func runLiveCadenceJobs(ctx context.Context, src pipeline.LiveSource, sink pipeline.LiveSink, cadence string, group []pipeline.LiveSpec, deadline time.Duration) {
	for _, spec := range group {
		if ctx.Err() != nil {
			zap.S().Warnw("overrun", "component", "live", "action", "tick", "event", "overrun", "cadence", cadence, "deadline", deadline, "job", spec.Key)
			break
		}
		pipeline.RunLiveSpec(ctx, src, sink, spec)
	}
}
