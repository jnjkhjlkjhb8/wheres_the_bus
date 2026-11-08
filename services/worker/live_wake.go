package main

import (
	"context"
	"sync"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bike"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/rail"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

type liveRun = func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error

// liveWakeTarget names the live spec a demand dataset wakes, and builds the run
// for one partition of it.
type liveWakeTarget struct {
	spec string
	run  func(partition string) liveRun
}

func liveWakeTargets(db *pgxpool.Pool, notifier bus.ArrivalNotifier, guard *pipeline.LiveFetchGuard) map[string]liveWakeTarget {
	return map[string]liveWakeTarget{
		"bus_eta": {spec: "bus", run: func(city string) liveRun {
			return func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return bus.EtaCity(ctx, city, fetch, sink, db, notifier, guard)
			}
		}},
		"bike": {spec: "bike", run: func(city string) liveRun {
			return func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return bike.EtaCity(ctx, city, fetch, sink, db, guard)
			}
		}},
		"tra": {spec: "tra", run: func(string) liveRun {
			return func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return rail.TraEta(ctx, fetch, sink, guard)
			}
		}},
		"thsr_seats": {spec: "thsr_seats", run: func(string) liveRun {
			return func(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
				return rail.ThsrAvailableSeats(ctx, fetch, sink, guard)
			}
		}},
	}
}

// liveWaker runs one live partition as soon as a stream creates its demand key,
// instead of leaving the first rider to wait for the next tick.
type liveWaker struct {
	src     pipeline.LiveSource
	sink    pipeline.LiveSink
	specs   map[string]pipeline.LiveSpec
	targets map[string]liveWakeTarget
	runs    sync.WaitGroup
}

// newLiveWaker wakes only the scheduled specs, so a job dropped for missing TDX
// credentials stays off however often it is woken.
func newLiveWaker(src pipeline.LiveSource, sink pipeline.LiveSink, specs []pipeline.LiveSpec, targets map[string]liveWakeTarget) *liveWaker {
	byKey := make(map[string]pipeline.LiveSpec, len(specs))
	for _, spec := range specs {
		byKey[spec.Key] = spec
	}
	return &liveWaker{src: src, sink: sink, specs: byKey, targets: targets}
}

// listen follows the wake channel until the returned stop is called. Each wake
// runs on its own goroutine, tracked in runs, so a slow city cannot hold up the
// next wake.
func (w *liveWaker) listen(rc *redis.Client) (stop func()) {
	sub := rc.Subscribe(context.Background(), shared.LiveWakeChannel)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for msg := range sub.Channel() {
			w.runs.Go(func() { w.wake(msg.Payload) })
		}
	}()
	return func() {
		if err := sub.Close(); err != nil {
			zap.S().Warnw("close failed", "component", "live", "action", "wake", "event", "close_failed", "err", err)
		}
		<-done
	}
}

// wake runs the partition a demand key names with the recovery, logging and
// deadline of its cron tick.
func (w *liveWaker) wake(key string) {
	spec, ok := w.resolve(key)
	if !ok {
		zap.S().Warnw("ignored", "component", "live", "action", "wake", "event", "ignored", "key", key, "reason", "no_scheduled_job")
		return
	}
	zap.S().Infow("wake", "component", "live", "action", "wake", "event", "wake", "key", key, "job", spec.Key)
	pipeline.WithTimeout(liveTickDeadline(spec.Cadence), func(ctx context.Context) {
		pipeline.RunLiveSpec(ctx, w.src, w.sink, spec)
	})
}

func (w *liveWaker) resolve(key string) (pipeline.LiveSpec, bool) {
	dataset, partition, ok := shared.ParseLiveDemandKey(key)
	target := w.targets[dataset]
	spec, scheduled := w.specs[target.spec]
	if !ok || !scheduled {
		return pipeline.LiveSpec{}, false
	}
	spec.Run = target.run(partition)
	return spec, true
}
