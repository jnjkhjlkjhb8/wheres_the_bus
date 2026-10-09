package main

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/cleanup"
)

// cleanupTestPool connects to DATABASE_URL and skips when it is unset. Unlike
// loaderTestPool it does not require the raw_tdx schema: this test provisions
// the one table it needs itself.
func cleanupTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping retention integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	return pool
}

func TestCleanupPredictionErrorsRetentionBoundary(t *testing.T) {
	pool := cleanupTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	if _, err := pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS bus_eta_prediction_error (
		sub_route_uid text, direction smallint, stop_uid text, source text,
		predicted_at timestamptz NOT NULL, predicted_seconds int, actual_seconds int)`); err != nil {
		t.Fatalf("provision: %v", err)
	}

	const sr = "TESTCLEANUP_SR"
	clean := func() {
		_, _ = pool.Exec(ctx, `DELETE FROM bus_eta_prediction_error WHERE sub_route_uid = $1`, sr)
	}
	clean()
	defer clean()

	for _, age := range []string{"31 days", "29 days"} {
		if _, err := pool.Exec(ctx, `
			INSERT INTO bus_eta_prediction_error (sub_route_uid, direction, stop_uid, source, predicted_at, predicted_seconds)
			VALUES ($1, 0, 'STOP_A', 'model', NOW() - $2::interval, 120)`, sr, age); err != nil {
			t.Fatalf("insert prediction error %s: %v", age, err)
		}
	}

	if err := cleanup.PredictionErrors(ctx, pool); err != nil {
		t.Fatalf("cleanupPredictionErrors: %v", err)
	}

	var total, old int
	err := pool.QueryRow(ctx, `SELECT COUNT(*), COUNT(*) FILTER (WHERE predicted_at < NOW() - INTERVAL '30 days')
		FROM bus_eta_prediction_error WHERE sub_route_uid = $1`, sr).Scan(&total, &old)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if total != 1 || old != 0 {
		t.Fatalf("after cleanup: total=%d old=%d, want only the 29-day row", total, old)
	}
}
