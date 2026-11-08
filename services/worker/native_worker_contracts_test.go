package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/puddle/v2"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
)

func workerContractLogs(t *testing.T) *observer.ObservedLogs {
	t.Helper()
	core, logs := observer.New(zapcore.DebugLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	return logs
}

func workerContractCause(entry observer.LoggedEntry) error {
	for _, field := range entry.Context {
		if field.Key == "err" {
			err, _ := field.Interface.(error)
			return err
		}
	}
	return nil
}

func workerContractFailure(t *testing.T, logs *observer.ObservedLogs, component, message string, cause error) {
	t.Helper()
	found := false
	for _, entry := range logs.All() {
		if entry.ContextMap()["component"] != component || entry.Message != message {
			continue
		}
		if !errors.Is(workerContractCause(entry), cause) {
			t.Fatalf("%s diagnostic lost original cause: %v", component, workerContractCause(entry))
		}
		found = true
	}
	if !found {
		t.Fatalf("%s failure diagnostic absent: %q", component, message)
	}
}

func workerContractRedis(t *testing.T) *redis.Client {
	t.Helper()
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	t.Cleanup(func() { _ = rc.Close() })
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	return rc
}

func workerContractHealth(t *testing.T, path string) {
	t.Helper()
	previous := _health
	t.Cleanup(func() { _health = previous })
	_health = newHealthFile(path)
}

func workerContractHTTPFailure(t *testing.T, cause error) {
	t.Helper()
	previous := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = previous })
	http.DefaultTransport = workerRoundTripper(func(*http.Request) (*http.Response, error) { return nil, cause })
}

func TestWorkerNativeRedisCloseFailureRetainsCause(t *testing.T) {
	logs := workerContractLogs(t)
	closeWorkerRedis(workerContractRedis(t))
	workerContractFailure(t, logs, "redis", "failed", redis.ErrClosed)
}

func TestWorkerNativeArchiveCloseFailureRetainsCause(t *testing.T) {
	logs := workerContractLogs(t)
	cause := errors.New("owned archive close failed")
	closeWorkerArchive(func() error { return cause })
	workerContractFailure(t, logs, "archive", "failed", cause)
}

func TestWorkerNativeCronHealthFailurePreservesPathAndCause(t *testing.T) {
	logs := workerContractLogs(t)
	path := filepath.Join(t.TempDir(), "missing-parent", "healthy")
	workerContractHealth(t, path)
	r := cron.New(cron.WithSeconds())
	ran := false
	id, err := addStaticCron(r, "@every 1h", func() { ran = true })
	if err != nil {
		t.Fatal(err)
	}
	r.Entry(id).Job.Run()
	if !ran {
		t.Fatal("health failure prevented the job")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unexpected marker: %v", err)
	}
	found := false
	for _, entry := range logs.All() {
		if entry.ContextMap()["component"] != "health" || entry.ContextMap()["path"] != path {
			continue
		}
		var pathErr *os.PathError
		if !errors.As(workerContractCause(entry), &pathErr) || pathErr.Path != path || !errors.Is(pathErr, os.ErrNotExist) {
			t.Fatalf("health diagnostic lost original path error: %v", workerContractCause(entry))
		}
		found = true
	}
	if !found {
		t.Fatal("failed health marker creation was silent")
	}
}

func workerContractBootFailure(t *testing.T, component, message string, refresh func()) {
	t.Helper()
	logs := workerContractLogs(t)
	cause := errors.New("owned boot refresh unavailable")
	workerContractHTTPFailure(t, cause)
	t.Setenv("CWA_API_KEY", "owned-test-key")
	refresh()
	workerContractFailure(t, logs, component, message, cause)
}

func TestWorkerNativeBootHolidayFailureRetainsCause(t *testing.T) {
	workerContractBootFailure(t, "holiday", "initial refresh failed; weekend/last-good fallback active", refreshBootHoliday)
}

func TestWorkerNativeBootWeatherFailureRetainsCause(t *testing.T) {
	workerContractBootFailure(t, "weather", "initial sync failed; keeping last good Redis snapshot", func() {
		refreshBootWeather(workerContractRedis(t))
	})
}

func workerContractMaintenanceFailure(t *testing.T, component, message string, offset int) {
	t.Helper()
	logs := workerContractLogs(t)
	cause := errors.New("owned scheduled refresh unavailable")
	workerContractHTTPFailure(t, cause)
	t.Setenv("CWA_API_KEY", "owned-test-key")
	t.Setenv("TDX_CLIENT_ID", "test-id")
	t.Setenv("TDX_CLIENT_SECRET", "test-secret")
	workerContractHealth(t, filepath.Join(t.TempDir(), "healthy"))
	r := cron.New(cron.WithSeconds())
	registerWorkerCrons(r, nil, workerContractRedis(t), nil)
	entries := r.Entries()
	if len(entries) != 11 {
		t.Fatalf("scheduled entries=%d", len(entries))
	}
	entries[len(entries)-offset].Job.Run()
	workerContractFailure(t, logs, component, message, cause)
	if _, err := os.Stat(_health.path); err != nil {
		t.Fatalf("failed refresh omitted health marker: %v", err)
	}
}

func TestWorkerNativeWeatherCronFailureRetainsCause(t *testing.T) {
	workerContractMaintenanceFailure(t, "weather", "sync failed; keeping last good Redis snapshot", 3)
}

func TestWorkerNativeHolidayCronFailureRetainsCause(t *testing.T) {
	workerContractMaintenanceFailure(t, "holiday", "refresh failed; keeping last good snapshot", 2)
}

func TestWorkerNativeGTFSCronFailureIsReportedWithoutPublish(t *testing.T) {
	logs := workerContractLogs(t)
	// A closed pool fails before any SQL, Redis snapshot write, or network request.
	db, err := pgxpool.New(context.Background(), "postgres://owned:owned@127.0.0.1:1/owned?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	workerContractHealth(t, filepath.Join(t.TempDir(), "healthy"))
	r := cron.New(cron.WithSeconds())
	registerGTFSRTCron(r, db, workerContractRedis(t))
	entries := r.Entries()
	if len(entries) != 1 {
		t.Fatalf("GTFS entries=%d", len(entries))
	}
	entries[0].Job.Run()
	failure := false
	for _, entry := range logs.All() {
		fields := entry.ContextMap()
		if fields["component"] != "gtfs_rt" || fields["action"] != "build" {
			continue
		}
		if fields["event"] == "success" {
			t.Fatal("failed GTFS build reported publication")
		}
		if fields["event"] == "failed" {
			cause := workerContractCause(entry)
			if !errors.Is(cause, puddle.ErrClosedPool) {
				t.Fatalf("GTFS build lost original database cause: %v", cause)
			}
			failure = true
		}
	}
	if !failure {
		t.Fatal("GTFS scheduled database failure was silent")
	}
	if _, err := os.Stat(_health.path); err != nil {
		t.Fatalf("failed GTFS build omitted liveness marker: %v", err)
	}
}

type workerContractDeadlineStore struct{ deadlines []time.Time }

func (s *workerContractDeadlineStore) Get(ctx context.Context, _ string) (string, error) {
	deadline, _ := ctx.Deadline()
	s.deadlines = append(s.deadlines, deadline)
	return "", errors.New("owned marker unavailable")
}
func (*workerContractDeadlineStore) Set(context.Context, string, string, time.Duration) error {
	return nil
}
func (*workerContractDeadlineStore) Del(context.Context, ...string) error { return nil }

func TestWorkerNativeManualLiveCommandBoundsFetchToTwoHours(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "off")
	t.Setenv("TDX_CLIENT_ID", "test-id")
	t.Setenv("TDX_CLIENT_SECRET", "test-secret")
	store := &workerContractDeadlineStore{}
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: store, IMSKey: shared.TDXLegacyIMSKey})
	before := time.Now()
	if err := runOnce("bikeeta", tdx, workerContractRedis(t), nil); err != nil {
		t.Fatal(err)
	}
	after := time.Now()
	if len(store.deadlines) == 0 {
		t.Fatal("manual live command never reached the fetch boundary")
	}
	for _, deadline := range store.deadlines {
		if deadline.Before(before.Add(2*time.Hour)) || deadline.After(after.Add(2*time.Hour)) {
			t.Fatalf("manual live fetch deadline is outside the two-hour command budget: %v", deadline)
		}
	}
}

func TestWorkerNativeShutdownDrainsAnAlreadyRunningShortJob(t *testing.T) {
	logs := workerContractLogs(t)
	workerContractHTTPFailure(t, errors.New("owned calendar unavailable"))
	t.Setenv("CWA_API_KEY", "")
	for _, name := range []string{"MQTT_CLIENT_ID", "MQTT_USERNAME", "MQTT_PASSWORD"} {
		t.Setenv(name, "")
	}
	t.Setenv("BUS_ETA_MODEL_PATH", filepath.Join(t.TempDir(), "absent-model.json"))
	workerContractHealth(t, filepath.Join(t.TempDir(), "healthy"))
	r := cron.New(cron.WithSeconds())
	started, release, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce, startOnce, finishOnce sync.Once
	releaseJob := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(func() {
		releaseJob()
		select {
		case <-r.Stop().Done():
		case <-time.After(5 * time.Second):
			t.Error("owned cron jobs did not stop")
		}
	})
	if _, err := addStaticCron(r, "@every 1s", func() {
		startOnce.Do(func() { close(started) })
		<-release
		finishOnce.Do(func() { close(finished) })
	}); err != nil {
		t.Fatal(err)
	}
	var releaseDone chan struct{}
	err := runRealtimeWithShutdown(r, nil, workerContractRedis(t), nil, func() {
		select {
		case <-started:
		case <-time.After(5 * time.Second):
			t.Fatal("owned scheduled job never started")
		}
		releaseDone = make(chan struct{})
		t.Cleanup(func() {
			select {
			case <-releaseDone:
			case <-time.After(5 * time.Second):
				t.Error("owned job release goroutine did not exit")
			}
		})
		go func() {
			defer close(releaseDone)
			time.Sleep(100 * time.Millisecond)
			releaseJob()
		}()
	})
	if releaseDone != nil {
		select {
		case <-releaseDone:
		case <-time.After(5 * time.Second):
			t.Fatal("owned job release goroutine did not exit")
		}
	}
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-finished:
	default:
		t.Fatal("shutdown returned before an already-running short job finished")
	}
	if logs.FilterMessage("jobs drained").Len() == 0 || logs.FilterMessage("grace timeout").Len() != 0 {
		t.Fatal("short in-flight job was not reported as drained")
	}
}
