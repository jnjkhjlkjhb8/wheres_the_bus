package main

import (
	"context"
	"errors"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/robfig/cron/v3"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

type workerRoundTripper func(*http.Request) (*http.Response, error)

func (f workerRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestWorkerBootStartsAndDrainsWithoutExternalCredentials(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" || os.Getenv("RIDER_REDIS_TEST_ADDR") == "" {
		t.Skip("requires disposable PostgreSQL and dedicated Rider Redis")
	}
	t.Setenv("REDIS_ADDR", os.Getenv("RIDER_REDIS_TEST_ADDR"))
	for _, name := range []string{"REDIS_PASSWORD", "TDX_CLIENT_ID", "TDX_CLIENT_SECRET", "MQTT_USERNAME", "MQTT_PASSWORD", "CWA_API_KEY", "ARCHIVE_MYSQL_DSN", "SENTRY_DSN"} {
		t.Setenv(name, "")
	}
	healthPath := filepath.Join(t.TempDir(), "healthy")
	t.Setenv("HEALTH_FILE", healthPath)
	oldHealth := _health
	t.Cleanup(func() { _health = oldHealth })
	oldTransport := http.DefaultTransport
	http.DefaultTransport = workerRoundTripper(func(r *http.Request) (*http.Response, error) {
		if !strings.Contains(r.URL.Path, "308dcd75-6434-45bc-a95f-584da4fed251") {
			t.Fatalf("unexpected outbound HTTP request: %s", r.URL.Path)
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("date,a,b,holiday\n20260101,x,x,是\n")), Header: make(http.Header), Request: r}, nil
	})
	t.Cleanup(func() { http.DefaultTransport = oldTransport })
	waits := 0
	if err := runWorker([]string{"functions"}, func() { waits++ }); err != nil {
		t.Fatal(err)
	}
	if waits != 1 {
		t.Fatalf("shutdown waits=%d", waits)
	}
	if _, err := os.Stat(healthPath); err != nil {
		t.Fatalf("worker health marker: %v", err)
	}
	if err := runWorker([]string{"functions", "run", "missing-job"}, func() { t.Fatal("manual run waited for signal") }); err == nil || !strings.Contains(err.Error(), "unknown job") {
		t.Fatalf("manual error=%v", err)
	}
	t.Setenv("ARCHIVE_MYSQL_DSN", "invalid-without-parse-time")
	if err := runWorker([]string{"functions"}, func() { t.Fatal("failed startup waited for signal") }); err == nil || !strings.Contains(err.Error(), "parseTime") {
		t.Fatalf("archive startup error=%v", err)
	}
}

func TestWorkerManualGTFSReturnsDatabaseFailure(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" {
		t.Skip("requires disposable PostgreSQL")
	}
	db, err := pgxpool.New(context.Background(), os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	defer func() { _ = rc.Close() }()
	if err := runOnce("gtfs-rt", nil, rc, db); err == nil || !strings.Contains(err.Error(), "gtfs-rt failed") {
		t.Fatalf("manual GTFS error=%v", err)
	}
}

func TestManualRunRequiresCommandAndJob(t *testing.T) {
	for _, args := range [][]string{nil, {"functions"}, {"functions", "run"}, {"functions", "other", "job"}} {
		if isManualWorkerRun(args) {
			t.Fatalf("accepted non-manual arguments %v", args)
		}
	}
	if !isManualWorkerRun([]string{"functions", "run", "traeta"}) {
		t.Fatal("manual run rejected")
	}
	var closedArchive bool
	closeWorkerArchive(func() error { closedArchive = true; return errors.New("close failed") })
	if !closedArchive {
		t.Fatal("archive cleanup not called")
	}
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	closeWorkerRedis(rc)
}

func TestWorkerExitCodeReportsOnlyFailures(t *testing.T) {
	var output strings.Builder
	if commandExitCode(nil, &output) != 0 || output.Len() != 0 {
		t.Fatal("successful command reported a failure")
	}
	if commandExitCode(errors.New("startup failed"), &output) != 1 || output.String() != "functions exited with error: startup failed\n" {
		t.Fatalf("failure output=%q", output.String())
	}
}

func TestLiveCadenceStopsBeforeDispatchWhenDeadlineEnds(t *testing.T) {
	var ran []string
	ctx, cancel := context.WithCancel(context.Background())
	specs := []pipeline.LiveSpec{
		{Key: "first", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			ran = append(ran, "first")
			cancel()
			return nil
		}},
		{Key: "second", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			ran = append(ran, "second")
			return nil
		}},
	}
	runLiveCadenceJobs(ctx, &fakeLiveSource{}, nil, "@every 30s", specs, time.Second)
	if len(ran) != 1 || ran[0] != "first" {
		t.Fatalf("deadline overrun dispatched jobs %v", ran)
	}
	runLiveCadence(&fakeLiveSource{}, nil, "@every 30s", nil, time.Second)
}

func TestWorkerMaintenanceCronCallbacks(t *testing.T) {
	oldTransport := http.DefaultTransport
	http.DefaultTransport = workerRoundTripper(func(r *http.Request) (*http.Response, error) { return nil, errors.New("calendar unavailable") })
	t.Cleanup(func() { http.DefaultTransport = oldTransport })
	t.Setenv("CWA_API_KEY", "")
	t.Setenv("TDX_CLIENT_ID", "test-id")
	t.Setenv("TDX_CLIENT_SECRET", "test-secret")
	oldHealth := _health
	_health = newHealthFile(filepath.Join(t.TempDir(), "healthy"))
	t.Cleanup(func() { _health = oldHealth })
	r := cron.New(cron.WithSeconds())
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	defer func() { _ = rc.Close() }()
	registerWorkerCrons(r, nil, rc, nil)
	entries := r.Entries()
	if len(entries) != 9 {
		t.Fatalf("scheduled jobs=%d", len(entries))
	}
	for _, entry := range entries[len(entries)-3:] {
		entry.Job.Run()
	}
	if _, err := os.Stat(_health.path); err != nil {
		t.Fatal(err)
	}
}

type failedWorkerTDXStore struct{ calls int }

func (s *failedWorkerTDXStore) Get(context.Context, string) (string, error) {
	s.calls++
	return "", errors.New("cache unavailable")
}
func (*failedWorkerTDXStore) Set(context.Context, string, string, time.Duration) error { return nil }
func (*failedWorkerTDXStore) Del(context.Context, ...string) error                     { return nil }

func TestManualLiveJobKeepsFailureInsideTheLiveRunner(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "off")
	t.Setenv("TDX_CLIENT_ID", "test-id")
	t.Setenv("TDX_CLIENT_SECRET", "test-secret")
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	store := &failedWorkerTDXStore{}
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: store, IMSKey: shared.TDXLegacyIMSKey})
	for _, job := range []string{"bikeeta", "traeta", "buseta"} {
		if err := runOnce(job, tdx, rc, nil); err != nil {
			t.Fatalf("%s returned a live job failure: %v", job, err)
		}
	}
	if store.calls == 0 {
		t.Fatal("manual jobs did not reach the live fetch seam")
	}
}
