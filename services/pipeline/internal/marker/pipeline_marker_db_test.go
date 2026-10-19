package marker

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestPostgresMarkerRetryAndReaderAgreeOnServiceDate(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required")
		}
		t.Skip("DATABASE_URL not set")
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `CREATE TEMP TABLE pipeline_runs(job text,run_date date,completed_at timestamptz DEFAULT now(),PRIMARY KEY(job,run_date))`); err != nil {
		t.Fatal(err)
	}
	reader := NewPGReader(pool)
	date := time.Date(2026, 10, 10, 8, 0, 0, 0, time.FixedZone("Taipei", 8*60*60))
	if exists, err := reader.MarkerExists(ctx, "vector", date); err != nil || exists {
		t.Fatalf("before record: %v %v", exists, err)
	}
	RecordWithRetry(ctx, pool, "vector", date)
	RecordWithRetry(ctx, pool, "vector", date)
	if exists, err := reader.MarkerExists(ctx, "vector", date); err != nil || !exists {
		t.Fatalf("after upsert: %v %v", exists, err)
	}
	if exists, err := reader.MarkerExists(ctx, "vector", date.AddDate(0, 0, 1)); err != nil || exists {
		t.Fatalf("other date: %v %v", exists, err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := reader.MarkerExists(canceled, "vector", date); err == nil {
		t.Fatal("canceled marker query accepted")
	}
	if err := recordPipelineMarker(canceled, pool, "vector", date); err == nil {
		t.Fatal("canceled marker write accepted")
	}
	RecordWithRetry(canceled, pool, "vector", date)
}

func TestPostgresMarkerRetriesTransientFailuresWithBackoff(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required")
		}
		t.Skip("DATABASE_URL not set")
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	for _, statement := range []string{
		`CREATE TEMP TABLE pipeline_runs(job text,run_date date,completed_at timestamptz DEFAULT now(),PRIMARY KEY(job,run_date))`,
		`CREATE TEMP SEQUENCE marker_attempts`,
		`CREATE FUNCTION pg_temp.fail_first_marker_attempts() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF nextval('pg_temp.marker_attempts') < 3 THEN RAISE EXCEPTION 'temporary marker failure'; END IF; RETURN NEW; END $$`,
		`CREATE TRIGGER retry_marker BEFORE INSERT ON pipeline_runs FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_first_marker_attempts()`,
	} {
		if _, err := pool.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	date := time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)
	started := time.Now()
	RecordWithRetry(ctx, pool, "retry", date)
	if elapsed := time.Since(started); elapsed < 15*time.Second {
		t.Fatalf("retry backoff shortened: %v", elapsed)
	}
	var attempts int
	if err := pool.QueryRow(ctx, `SELECT last_value FROM pg_temp.marker_attempts`).Scan(&attempts); err != nil {
		t.Fatal(err)
	}
	if attempts != 3 {
		t.Fatalf("marker attempts = %d, want 3", attempts)
	}
	if exists, err := NewPGReader(pool).MarkerExists(ctx, "retry", date); err != nil || !exists {
		t.Fatalf("retried marker = %v, %v", exists, err)
	}
	if entries := logs.FilterMessage("recorded").All(); len(entries) != 1 || entries[0].ContextMap()["job"] != "retry" {
		t.Fatalf("success events = %+v", entries)
	}
	canceled, stop := context.WithCancel(ctx)
	stop()
	RecordWithRetry(canceled, pool, "canceled", date)
	if entries := logs.FilterMessage("failed").All(); len(entries) != 1 || entries[0].ContextMap()["job"] != "canceled" {
		t.Fatalf("failure events = %+v", entries)
	}
}

func TestMarkerPollingUsesFiveMinutesWithinTwoHours(t *testing.T) {
	if PollInterval != 5*time.Minute || PollDeadline != 2*time.Hour {
		t.Fatalf("poll configuration = %v / %v", PollInterval, PollDeadline)
	}
}
