package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/redis/go-redis/v9"
)

func riderWorkerTestPool(t *testing.T) (*pgxpool.Pool, string) {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL required")
	}
	admin, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("quality_rider_worker_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(context.Background(), "CREATE SCHEMA "+quoted+"; CREATE TABLE "+quoted+".firebase_arrival_reminder (route_key text,route_type text,status text,expires_at timestamptz)"); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+quoted+" CASCADE"); admin.Close() })
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool, schema
}

func riderWorkerTestRedis(t *testing.T) *redis.Client {
	t.Helper()
	// Boot uses the shared client on DB 0, so this test has a dedicated local instance.
	addr := os.Getenv("RIDER_REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("RIDER_REDIS_TEST_ADDR required")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	if err := rc.Ping(context.Background()).Err(); err != nil {
		rc.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		rc.Del(context.Background(), shared.LiveDemandKey("bus_eta", "Taipei"), shared.LiveDemandKey("bus_eta", "Kaohsiung"), riderevent.StreamKey)
		_ = rc.Close()
	})
	return rc
}

// recordingDemand records each demand claim's TTL by key. The max-TTL rule
// itself is RedisDemand's and is tested with it.
type recordingDemand map[string]time.Duration

func (d recordingDemand) Touch(_ context.Context, key string, ttl time.Duration) { d[key] = ttl }

func TestRestoreReminderDemandFiltersAndExtendsLatestExpiry(t *testing.T) {
	db, _ := riderWorkerTestPool(t)
	ctx := context.Background()
	if _, err := db.Exec(ctx, `INSERT INTO firebase_arrival_reminder VALUES
 ('TPEroute1','bus','pending',NOW()+INTERVAL '1 hour'),
 ('TPEroute2','bus','pending',NOW()+INTERVAL '2 hours'),
 ('KHHroute','bus','pending',NOW()+INTERVAL '1 hour'),
 ('XXXroute','bus','pending',NOW()+INTERVAL '1 hour'),
 ('TPEexpired','bus','pending',NOW()-INTERVAL '1 minute'),
 ('TPErail','tra','pending',NOW()+INTERVAL '1 hour'),
 ('TPEfired','bus','fired',NOW()+INTERVAL '1 hour')`); err != nil {
		t.Fatal(err)
	}
	sink := recordingDemand{}
	if got := restoreReminderDemand(ctx, db, sink); got != 2 || len(sink) != 2 {
		t.Fatalf("restored=%d claims=%v", got, sink)
	}
	if ttl := sink[shared.LiveDemandKey("bus_eta", "Taipei")]; ttl < 119*time.Minute || ttl > 2*time.Hour {
		t.Fatalf("latest expiry TTL=%v", ttl)
	}
	if ttl := sink[shared.LiveDemandKey("bus_eta", "Kaohsiung")]; ttl < 59*time.Minute || ttl > time.Hour {
		t.Fatalf("Kaohsiung TTL=%v", ttl)
	}
	if restoreReminderDemand(ctx, nil, sink) != 0 || restoreReminderDemand(ctx, db, nil) != 0 {
		t.Fatal("nil dependencies restored")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if restoreReminderDemand(cancelled, db, sink) != 0 {
		t.Fatal("canceled query restored")
	}
	if _, err := db.Exec(ctx, "DELETE FROM firebase_arrival_reminder"); err != nil {
		t.Fatal(err)
	}
	if restoreReminderDemand(ctx, db, sink) != 0 {
		t.Fatal("empty query restored")
	}
}

func TestRiderWorkerNativeBootAndDrainWithoutPush(t *testing.T) {
	_, schema := riderWorkerTestPool(t)
	rc := riderWorkerTestRedis(t)
	t.Setenv("REDIS_ADDR", rc.Options().Addr)
	t.Setenv("REDIS_PASSWORD", "")
	t.Setenv("PG_SCHEMA", schema)
	t.Setenv("FIREBASE_ENABLED", "false")
	t.Setenv("APP_ENV", "dev")
	t.Setenv("APNS_KEY_ID", "")
	path := filepath.Join(t.TempDir(), "healthy")
	t.Setenv("HEALTH_FILE", path)
	old := _health
	t.Cleanup(func() { _health = old })
	shutdownCalls := 0
	if err := runRiderWorker(func() { shutdownCalls++ }); err != nil {
		t.Fatal(err)
	}
	if shutdownCalls != 1 {
		t.Fatalf("shutdown calls=%d", shutdownCalls)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("boot health marker=%v", err)
	}
}

func TestRiderAPINativeBootUsesIsolatedListeners(t *testing.T) {
	_, schema := riderWorkerTestPool(t)
	rc := riderWorkerTestRedis(t)
	t.Setenv("REDIS_ADDR", rc.Options().Addr)
	t.Setenv("REDIS_PASSWORD", "")
	t.Setenv("PG_SCHEMA", schema)
	t.Setenv("RIDER_TLS_DIR", "")
	calls := 0
	if err := runRiderAPI(func() { calls++ }, "127.0.0.1:0", "127.0.0.1:0"); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("shutdown calls=%d", calls)
	}
	if err := runRiderAPI(func() {}, "invalid address", "127.0.0.1:0"); err == nil {
		t.Fatal("invalid listen address accepted")
	}
}

func TestTouchCityDemandSkipsUnknownCitiesAndSpentReminders(t *testing.T) {
	sink := recordingDemand{}
	for _, tc := range []struct {
		prefix string
		ttl    time.Duration
		want   int
	}{{"XXX", time.Hour, 0}, {"TPE", 0, 0}, {"TPE", -time.Second, 0}, {"KHH", time.Nanosecond, 1}} {
		if got := touchCityDemand(t.Context(), sink, tc.prefix, tc.ttl); got != tc.want {
			t.Fatalf("touchCityDemand(%s, %v)=%d", tc.prefix, tc.ttl, got)
		}
	}
	if len(sink) != 1 || sink[shared.LiveDemandKey("bus_eta", "Kaohsiung")] != time.Nanosecond {
		t.Fatalf("claims=%v", sink)
	}
}
