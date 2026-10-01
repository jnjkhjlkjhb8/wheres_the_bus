package main

import (
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
)

func TestRunLegacyProdRoutesBootLoadThroughStaticGuard(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var legacy *ast.FuncDecl
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if ok && fn.Name.Name == "runLegacyProd" {
			legacy = fn
			break
		}
	}
	if legacy == nil {
		t.Fatal("runLegacyProd declaration not found")
	}
	var guardedBootCalls, directLoadCalls int
	ast.Inspect(legacy.Body, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		ident, ok := call.Fun.(*ast.Ident)
		if !ok {
			return true
		}
		switch ident.Name {
		case "runBootBusDailyTimetable":
			guardedBootCalls++
		case "runLoad":
			directLoadCalls++
		}
		return true
	})
	if guardedBootCalls != 1 {
		t.Fatalf("runLegacyProd guarded boot calls = %d, want 1", guardedBootCalls)
	}
	if directLoadCalls != 0 {
		t.Fatalf("runLegacyProd direct runLoad calls = %d, want 0", directLoadCalls)
	}
}

func TestChangeToVectorBoundToLoader(t *testing.T) {
	countCalls := func(file, fnName, callee string) int {
		parsed, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		var target *ast.FuncDecl
		for _, decl := range parsed.Decls {
			if fn, ok := decl.(*ast.FuncDecl); ok && fn.Name.Name == fnName {
				target = fn
				break
			}
		}
		if target == nil {
			t.Fatalf("%s declaration not found in %s", fnName, file)
		}
		n := 0
		ast.Inspect(target.Body, func(node ast.Node) bool {
			if call, ok := node.(*ast.CallExpr); ok {
				if ident, ok := call.Fun.(*ast.Ident); ok && ident.Name == callee {
					n++
				}
			}
			return true
		})
		return n
	}
	if got := countCalls("loader_cron.go", "runLoadStage", "runVectorRefresh"); got != 1 {
		t.Fatalf("runLoadStage runVectorRefresh calls = %d, want 1 (the load->vector chain)", got)
	}
	if got := countCalls("loader_cron.go", "registerLoaderCrons", "runLoadStage"); got != 2 {
		t.Fatalf("registerLoaderCrons runLoadStage calls = %d, want 2 (cron + boot)", got)
	}
	if got := countCalls("main.go", "runLegacyProd", "runVectorRefresh"); got != 0 {
		t.Fatalf("runLegacyProd runVectorRefresh calls = %d, want 0 (moved to loader)", got)
	}
}

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
func TestRunStaticJobWaitsForUpstreamMarker(t *testing.T) {
	// errUntil 0 with a non-nil err makes every poll fail, so the wait gives up.
	reader := &fakeMarkerReader{err: errors.New("pipeline_runs unavailable")}
	// 45-minute steps push the clock past the 2h deadline after a few polls.
	clock := &fakeClock{t: time.Unix(0, 0), step: 45 * time.Minute}
	ran := false
	runStaticJob(reader, staticJobSpec{
		name: "segmentTimes", waitFor: "changetovector",
		run: func(context.Context) error { ran = true; return nil },
	}, clock.now, noopSleep, 0)
	if ran {
		t.Fatal("job ran without its upstream marker")
	}
	if reader.gotJob != "changetovector" {
		t.Fatalf("polled marker = %q, want changetovector", reader.gotJob)
	}
}

// TestRunStaticJobRunsOnceMarkerLands is the mirror: a present marker lets the
// job through, and a spec with no waitFor never polls at all.
func TestRunStaticJobRunsOnceMarkerLands(t *testing.T) {
	reader := &fakeMarkerReader{readyAfter: 1}
	runs := 0
	runStaticJob(reader, staticJobSpec{
		name: "segmentTimes", waitFor: "changetovector",
		run: func(context.Context) error { runs++; return nil },
	}, (&fakeClock{t: time.Unix(0, 0)}).now, noopSleep, 0)
	if runs != 1 {
		t.Fatalf("runs = %d, want 1", runs)
	}

	unpolled := &fakeMarkerReader{readyAfter: 1}
	runStaticJob(unpolled, staticJobSpec{
		name: "cleanups",
		run:  func(context.Context) error { return nil },
	}, time.Now, noopSleep, 0)
	if unpolled.calls != 0 {
		t.Fatalf("MarkerExists calls = %d, want 0 for a spec with no upstream", unpolled.calls)
	}
}

// TestRunStaticJobRetriesTransientFailure pins that attempts above 1 actually
// retries: measurePredictionError relies on it, and a spec that silently ran
// once would turn a blip into a lost nightly run.
func TestRunStaticJobRetriesTransientFailure(t *testing.T) {
	attempts := 0
	runStaticJob(&fakeMarkerReader{}, staticJobSpec{
		name: "measurePredictionError", timeout: time.Second, attempts: 3,
		run: func(context.Context) error {
			attempts++
			if attempts < 3 {
				return errors.New("transient")
			}
			return nil
		},
	}, time.Now, noopSleep, 0)
	if attempts != 3 {
		t.Fatalf("attempts = %d, want 3", attempts)
	}
}

// Marker-wait fakes. The marker package keeps its own copies for the wait
// loop itself; these drive the cron registration around it.

// fakeMarkerReader reports the marker present starting from readyAfter calls,
// returning err for the first errUntil calls (errUntil == 0 with a non-nil err
// means every call errors); it also records every job/date it was asked about.
type fakeMarkerReader struct {
	readyAfter int
	errUntil   int
	calls      int
	err        error
	gotJob     string
	gotDate    time.Time
}

func (f *fakeMarkerReader) MarkerExists(_ context.Context, job string, runDate time.Time) (bool, error) {
	f.calls++
	f.gotJob = job
	f.gotDate = runDate
	if f.err != nil && (f.errUntil == 0 || f.calls <= f.errUntil) {
		return false, f.err
	}
	return f.calls >= f.readyAfter, nil
}

// fakeClock advances by one interval step each time now() is read, letting
// tests control elapsed time without real waits.
type fakeClock struct {
	t    time.Time
	step time.Duration
}

func (c *fakeClock) now() time.Time {
	current := c.t
	c.t = c.t.Add(c.step)
	return current
}

func noopSleep(context.Context, time.Duration) error { return nil }

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
