package main

import (
	"bytes"
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/gtfs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
)

func TestPipelineCLIUsageAndConnectionLifecycle(t *testing.T) {
	var stderr bytes.Buffer
	if code := runPipelineCLI(nil, &stderr); code != 1 || !strings.Contains(stderr.String(), "usage: pipeline run") {
		t.Fatalf("invalid usage = %d, %q", code, stderr.String())
	}
	loaderTestPool(t)
	t.Setenv("ARCHIVE_MYSQL_DSN", "")
	t.Setenv("TDX_CLIENT_ID", "")
	t.Setenv("TDX_CLIENT_SECRET", "")
	previousDB, previousDump := raw.DB, raw.DumpEnabled
	t.Cleanup(func() { raw.DB, raw.DumpEnabled = previousDB, previousDump })
	stderr.Reset()
	if code := runPipelineCLI([]string{"run", "unknown"}, &stderr); code != 1 || !strings.Contains(stderr.String(), "unknown pipeline step") {
		t.Fatalf("unknown step = %d, %q", code, stderr.String())
	}
	stderr.Reset()
	if code := runPipelineCLI([]string{"run", "ingest"}, &stderr); code != 0 || stderr.Len() != 0 {
		t.Fatalf("idle ingestor = %d, %q", code, stderr.String())
	}
}

func TestPipelineRunLockContentionCancellationAndRelease(t *testing.T) {
	pool := loaderTestPool(t)
	// A broken acquisition must reach an assertion before the package timeout.
	ctx, cancelAcquisition := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelAcquisition()
	lock, err := acquireRunLock(ctx, pool, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lock.release() })
	if _, err := acquireRunLock(ctx, pool, 0, 0); !errors.Is(err, errRunLockBusy) {
		t.Fatalf("contended lock = %v", err)
	}
	if err := runHourly(ctx, deps{rawPool: pool}); err != nil {
		t.Fatalf("hourly did not skip busy lock: %v", err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := acquireRunLock(cancelled, pool, time.Second, time.Millisecond); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled lock = %v", err)
	}
	if err := waitPipelineRunLockRetry(cancelled, time.Now().Add(time.Hour), time.Millisecond); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled retry = %v", err)
	}
	if err := waitPipelineRunLockRetry(ctx, time.Now().Add(time.Hour), time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if err := runNightly(cancelled, deps{rawPool: pool}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled nightly = %v", err)
	}
	if err := runHourly(cancelled, deps{rawPool: pool}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled hourly = %v", err)
	}
	releasePipelineRunLock(lock)
	if _, err := tryPipelineRunLock(ctx, lock.conn, time.Now(), 0); err == nil {
		t.Fatal("query on released lock succeeded")
	}
	second, err := acquireRunLock(ctx, pool, time.Second, time.Millisecond)
	if err != nil {
		t.Fatalf("released lock remained held: %v", err)
	}
	if err := second.release(); err != nil {
		t.Fatal(err)
	}
}

func TestNightlyStopsAtFailureAndPreservesStageContext(t *testing.T) {
	want := errors.New("load failed")
	for _, failed := range []bool{false, true} {
		var order []string
		steps := []step{
			{"ingest", func(context.Context, deps) error { order = append(order, "ingest"); return nil }},
			{"load", func(context.Context, deps) error {
				order = append(order, "load")
				if failed {
					return want
				}
				return nil
			}},
			{"gtfs", func(context.Context, deps) error { order = append(order, "gtfs"); return nil }},
		}
		err := runNightlySteps(context.Background(), deps{}, steps)
		expected := []string{"ingest", "load", "gtfs"}
		if failed {
			expected = expected[:2]
			if !errors.Is(err, want) || !strings.Contains(err.Error(), "load") {
				t.Fatalf("failure context = %v", err)
			}
		} else if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(order, expected) {
			t.Fatalf("step order = %v", order)
		}
	}
}

func TestPipelineEntryHelpersAndCancelledStages(t *testing.T) {
	t.Setenv("GTFS_OUT_DIR", "")
	if got := gtfsRoot(); got != "/data/gtfs" {
		t.Fatalf("default feed root = %q", got)
	}
	t.Setenv("GTFS_OUT_DIR", t.TempDir())
	if got := gtfsRoot(); got == "/data/gtfs" {
		t.Fatal("configured feed root ignored")
	}
	t.Setenv("PIPELINE_RUN_ID", "")
	if got := runID(); !strings.HasPrefix(got, "manual-") {
		t.Fatalf("manual identity = %q", got)
	}
	t.Setenv("PIPELINE_RUN_ID", "quality-run")
	if got := runID(); got != "quality-run" {
		t.Fatalf("job identity = %q", got)
	}
	if err := handlePipelinePublishError(gtfs.ErrStaleRun, gtfs.Manifest{}); err != nil {
		t.Fatal(err)
	}
	want := errors.New("database unavailable")
	if err := handlePipelinePublishError(want, gtfs.Manifest{}); !errors.Is(err, want) {
		t.Fatal(err)
	}
	closePipelineResource(func() error { return nil }, "test")
	closePipelineResource(func() error { return want }, "test")
	pool := loaderTestPool(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := publishPipelineRun(ctx, pool, gtfs.Manifest{RunID: "cancelled", BuildSeq: 1}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled publish stage = %v", err)
	}
	prunePublishedPipelineRuns(ctx, pool)
	rc := unavailableRedisClient()
	defer func() { _ = rc.Close() }()
	if err := loadHourlyDailyTimetable(ctx, deps{rc: rc}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled hourly load = %v", err)
	}
	t.Setenv("TDX_CLIENT_ID", "")
	t.Setenv("TDX_CLIENT_SECRET", "")
	if err := ingestHourlyDailyTimetable(ctx, deps{}); err != nil {
		t.Fatalf("disabled hourly ingestor = %v", err)
	}
	previous := raw.DB
	raw.DB = pool
	defer func() { raw.DB = previous }()
	reportFullRawIngest(ctx, nil)
	for name, stage := range map[string]func(context.Context, deps) error{
		"load": stepLoad, "segment times": stepSegmentTimes, "prediction errors": stepPredictionErrors,
		"gtfs": stepGTFS, "publish": runPublish, "hourly ingest": runHourlyDailyTimetable,
	} {
		if err := stage(ctx, deps{db: pool, rawPool: pool}); err == nil {
			t.Errorf("cancelled %s succeeded", name)
		}
	}
}

func TestLoadSpecSelectionPreservesOrderAndFiltersUnknownKeys(t *testing.T) {
	specs := []loadSpec{{key: "first"}, {key: "second"}, {key: "third"}}
	if got := selectLoadSpecs(specs, nil); len(got) != 3 {
		t.Fatalf("all specs = %v", got)
	}
	got := selectLoadSpecs(specs, []string{"third", "first", "missing"})
	if len(got) != 2 || got[0].key != "first" || got[1].key != "third" {
		t.Fatalf("filtered specs = %v", got)
	}
}
