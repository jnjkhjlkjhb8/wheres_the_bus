package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/redis/go-redis/v9"
)

func TestVectorRefreshJobPropagatesError(t *testing.T) {
	wantErr := errors.New("watermark unavailable")
	job := vectorRefreshJob(&testVectorRedis{getErr: wantErr}, nil)
	if err := job(context.Background()); !errors.Is(err, wantErr) {
		t.Fatalf("vectorRefreshJob() error = %v, want wrapped %v", err, wantErr)
	}
}

func TestRunDailyRetriesLoadPartitionFailure(t *testing.T) {
	partitionErr := errors.New("load partition failed")
	attempts := 0
	err := pipeline.RunDailyWithRetry(context.Background(), 100*time.Millisecond, 0, func(context.Context) error {
		attempts++
		if attempts == 1 {
			return partitionErr
		}
		return nil
	})
	if err != nil {
		t.Fatalf("runDailyWithRetry returned %v", err)
	}
	if attempts != 2 {
		t.Fatalf("attempts = %d, want 2", attempts)
	}
}

// no cron work in flight; isolate the boot-goroutine wait

// TestDrainShutdownBoundedByGraceTimeout proves a job that never finishes
// cannot hang the process forever: drainShutdown must return once the grace
// period elapses even though the tracked work is still outstanding.

// deliberately never Done: simulates a stuck boot job

// TestRunStaticJobWaitsForUpstreamMarker pins the gate the 04:00 chain depends
// on: a job declaring waitFor must not run when its upstream stage never
// finished, or the segment-time passes rebuild the table from a stale corpus.

// errUntil 0 with a non-nil err makes every poll fail, so the wait gives up.

// 45-minute steps push the clock past the 2h deadline after a few polls.

// TestRunStaticJobRunsOnceMarkerLands is the mirror: a present marker lets the
// job through, and a spec with no waitFor never polls at all.

// TestRunStaticJobRetriesTransientFailure pins that attempts above 1 actually
// retries: measurePredictionError relies on it, and a spec that silently ran
// once would turn a blip into a lost nightly run.

// Marker-wait fakes. The marker package keeps its own copies for the wait
// loop itself; these drive the cron registration around it.

// fakeMarkerReader reports the marker present starting from readyAfter calls,
// returning err for the first errUntil calls (errUntil == 0 with a non-nil err
// means every call errors); it also records every job/date it was asked about.

// fakeClock advances by one interval step each time now() is read, letting
// tests control elapsed time without real waits.

// Vector-refresh redis fake. The vector package keeps its own copy for the
// refresh itself; this one drives the cron job wrapper.

type testVectorRedis struct {
	value          string
	getErr         error
	setErr         error
	setValues      []string
	successfulSets int
}

func (r *testVectorRedis) Get(context.Context, string) *redis.StringCmd {
	return redis.NewStringResult(r.value, r.getErr)
}

func (r *testVectorRedis) Set(_ context.Context, _ string, value any, _ time.Duration) *redis.StatusCmd {
	r.setValues = append(r.setValues, fmt.Sprint(value))
	if r.setErr == nil {
		r.successfulSets++
	}
	return redis.NewStatusResult("OK", r.setErr)
}

func TestNightlyStepOrder(t *testing.T) {
	var got []string
	for _, s := range nightlySteps() {
		got = append(got, s.name)
	}
	want := []string{"ingest", "load", "vector", "segment_times", "gtfs", "prediction_errors"}
	if !slices.Equal(got, want) {
		t.Fatalf("nightly steps = %v, want %v", got, want)
	}
}

func TestRunRejectsUnknownUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"nightly"}, {"go", "nightly"}, {"run", "a", "b"}} {
		if err := run(args); err == nil {
			t.Errorf("run(%q) = nil, want usage error", args)
		}
	}
}
