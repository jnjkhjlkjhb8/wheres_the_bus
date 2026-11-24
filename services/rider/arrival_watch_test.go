package main

import (
	"context"
	"fmt"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

// arrivalWatchTestPool returns a pool whose search_path is a throwaway schema
// holding only the reminder columns the watch query reads.
func arrivalWatchTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	schema := pgx.Identifier{fmt.Sprintf("quality_arrival_watch_%d_%d", os.Getpid(), time.Now().UnixNano())}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema+"; CREATE TABLE "+schema+
		".firebase_arrival_reminder (route_type text, route_key text, stop_key text, direction text, status text, expires_at timestamptz)"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE") })
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func arrivalWatchTestRedis(t *testing.T) *redis.Client {
	t.Helper()
	addr := os.Getenv("RIDER_REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("RIDER_REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 1})
	t.Cleanup(func() {
		_ = rc.Del(context.Background(), riderevent.WatchKey).Err()
		_ = rc.Close()
	})
	return rc
}

// failedRefreshLogs counts the refresh failures runArrivalWatchRefresh logs.
func failedRefreshLogs(t *testing.T) func() int {
	t.Helper()
	core, logs := observer.New(zap.ErrorLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	return func() int {
		return logs.FilterField(zap.String("action", "refresh_watch")).Len()
	}
}

func TestArrivalWatchListsRemindersThatCanStillFire(t *testing.T) {
	db := arrivalWatchTestPool(t)
	rc := arrivalWatchTestRedis(t)
	failures := failedRefreshLogs(t)
	ctx := context.Background()
	if _, err := db.Exec(ctx, `INSERT INTO firebase_arrival_reminder VALUES
		('bus','R1','S1','0','pending',NOW()+INTERVAL '1 hour'),
		('bus','R1','S1','0','pending',NOW()+INTERVAL '2 hours'),
		('bus','R2','S2','1','sending',NOW()+INTERVAL '1 hour'),
		('bus','R3','S3','0','fired',NOW()+INTERVAL '1 hour'),
		('bus','R4','S4','0','cancelled',NOW()+INTERVAL '1 hour'),
		('bus','R5','S5','0','pending',NOW()-INTERVAL '1 minute')`); err != nil {
		t.Fatal(err)
	}

	runArrivalWatchRefresh(db, rc)

	if n := failures(); n != 0 {
		t.Fatalf("a successful refresh logged %d failures", n)
	}
	got, err := rc.SMembers(ctx, riderevent.WatchKey).Result()
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(got)
	want := []string{riderevent.WatchMember("bus", "R1", "S1", "0"), riderevent.WatchMember("bus", "R2", "S2", "1")}
	if !slices.Equal(got, want) {
		t.Fatalf("watch = %v, want %v", got, want)
	}
}

func TestArrivalWatchKeepsTheLastSetWhenTheQueryFails(t *testing.T) {
	db := arrivalWatchTestPool(t)
	rc := arrivalWatchTestRedis(t)
	ctx := context.Background()
	if err := riderevent.StoreWatch(ctx, rc, []string{"kept"}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, "ALTER TABLE firebase_arrival_reminder DROP COLUMN direction"); err != nil {
		t.Fatal(err)
	}
	failures := failedRefreshLogs(t)
	runArrivalWatchRefresh(db, rc)
	if n := failures(); n != 1 {
		t.Fatalf("a failed query logged %d failures, want 1", n)
	}
	if got := rc.SMembers(ctx, riderevent.WatchKey).Val(); !slices.Equal(got, []string{"kept"}) {
		t.Fatalf("watch = %v, want the last good set", got)
	}

	if _, err := db.Exec(ctx, "ALTER TABLE firebase_arrival_reminder ADD COLUMN direction int; "+
		"INSERT INTO firebase_arrival_reminder VALUES ('bus','R1','S1','pending',NOW()+INTERVAL '1 hour',NULL)"); err != nil {
		t.Fatal(err)
	}
	if err := refreshArrivalWatch(ctx, db, rc); err == nil {
		t.Fatal("an unscannable row reported success")
	}
}
