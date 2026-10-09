package main

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/robfig/cron/v3"
)

func TestMask(t *testing.T) {
	got := pipeline.Mask(true, false, true, false, false, false, true)
	want := uint8((1 << 0) | (1 << 2) | (1 << 6))
	if got != want {
		t.Fatalf("pipeline.Mask() = %d, want %d", got, want)
	}
}

func TestMask2(t *testing.T) {
	got := pipeline.Mask2(0, 1, 0, 0, 0, 1, 0)
	want := uint8((1 << 1) | (1 << 5))
	if got != want {
		t.Fatalf("pipeline.Mask2() = %d, want %d", got, want)
	}
}

func TestDrainShutdownWaitsForBootJobBeforeReturning(t *testing.T) {
	var boot sync.WaitGroup
	var jobFinished atomic.Bool
	boot.Add(1)
	go func() {
		defer boot.Done()
		time.Sleep(50 * time.Millisecond)
		jobFinished.Store(true)
	}()

	alreadyStoppedCron, cancel := context.WithCancel(context.Background())
	cancel() // no cron work in flight; isolate the boot-goroutine wait

	start := time.Now()
	drainShutdown(alreadyStoppedCron, &boot, time.Second)
	elapsed := time.Since(start)

	if !jobFinished.Load() {
		t.Fatal("drainShutdown returned before the tracked boot job finished")
	}
	if elapsed < 50*time.Millisecond {
		t.Fatalf("drainShutdown returned after %v, want it to have waited for the 50ms job", elapsed)
	}
}

// TestDrainShutdownBoundedByGraceTimeout proves a job that never finishes
// cannot hang the process forever: drainShutdown must return once the grace
// period elapses even though the tracked work is still outstanding.
func TestDrainShutdownBoundedByGraceTimeout(t *testing.T) {
	var boot sync.WaitGroup
	boot.Add(1) // deliberately never Done: simulates a stuck boot job
	t.Cleanup(boot.Done)

	neverDone, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	const grace = 50 * time.Millisecond
	start := time.Now()
	drainShutdown(neverDone, &boot, grace)
	elapsed := time.Since(start)

	if elapsed < grace {
		t.Fatalf("drainShutdown returned after %v, want at least the %v grace period", elapsed, grace)
	}
	if elapsed > grace+500*time.Millisecond {
		t.Fatalf("drainShutdown returned after %v, want it bounded near the %v grace period", elapsed, grace)
	}
}

func TestAddStaticCronSkipsOverlappingEntry(t *testing.T) {
	r := cron.New(cron.WithSeconds())
	var runs atomic.Int64
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	id, err := addStaticCron(r, "@every 1h", func() {
		runs.Add(1)
		started <- struct{}{}
		<-release
	})
	if err != nil {
		t.Fatalf("addStaticCron: %v", err)
	}
	entry := r.Entry(id)
	if entry.Job == nil {
		t.Fatal("registered entry has no Job")
	}

	go entry.Job.Run()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first invocation never started")
	}

	secondDone := make(chan struct{})
	go func() {
		entry.Job.Run()
		close(secondDone)
	}()
	select {
	case <-secondDone:
	case <-time.After(time.Second):
		t.Fatal("overlapping invocation did not return promptly; addStaticCron did not skip it")
	}

	close(release)
	if got := runs.Load(); got != 1 {
		t.Fatalf("addStaticCron job ran %d times, want exactly 1 (overlapping invocation must be skipped)", got)
	}
}

func TestLiveTickDeadlineStaysUnderCadence(t *testing.T) {
	tests := []struct {
		cadence string
		period  time.Duration
	}{
		{"@every 10s", 10 * time.Second},
		{"@every 30s", 30 * time.Second},
		{"@every 2m", 2 * time.Minute},
		{"@every 10m", 10 * time.Minute},
	}
	for _, tt := range tests {
		t.Run(tt.cadence, func(t *testing.T) {
			got := liveTickDeadline(tt.cadence)
			if got <= 0 || got >= tt.period {
				t.Fatalf("liveTickDeadline(%q) = %v, want strictly between 0 and %v", tt.cadence, got, tt.period)
			}
		})
	}
	if got := liveTickDeadline("@every 30s"); got != _liveJobTimeout {
		t.Fatalf("liveTickDeadline(@every 30s) = %v, want liveJobTimeout %v (unchanged bus/bike behavior)", got, _liveJobTimeout)
	}
}

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
