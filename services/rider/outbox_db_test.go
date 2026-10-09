package main

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

type recordingAlerter struct{ sent []string }

func (a *recordingAlerter) RouteAlert(_ context.Context, routeType, routeKey, _ string) {
	a.sent = append(a.sent, routeType+"/"+routeKey)
}

func outboxTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required for DB integration tests")
		}
		t.Skip("DATABASE_URL not set")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	var exists bool
	if err := pool.QueryRow(context.Background(),
		`SELECT to_regclass('route_alert_outbox') IS NOT NULL`).Scan(&exists); err != nil || !exists {
		t.Fatalf("route_alert_outbox missing (err=%v); apply migrations/2026-10-08-route-alert-outbox.sql", err)
	}
	if _, err := pool.Exec(context.Background(), `DELETE FROM route_alert_outbox`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = pool.Exec(context.Background(), `DELETE FROM route_alert_outbox`) })
	return pool
}

func TestDrainRouteAlertOutboxSendsEachPendingAlertOnce(t *testing.T) {
	pool := outboxTestPool(t)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `
		INSERT INTO route_alert_outbox (dedupe_key, route_type, route_key, body, created_at, attempts, processed_at, claimed_until) VALUES
		('fresh',     'bus', 'R1', 'x', now(),                       0, NULL,  NULL),
		('done',      'bus', 'R2', 'x', now(),                       1, now(), NULL),
		('too-old',   'bus', 'R3', 'x', now() - interval '25 hours', 0, NULL,  NULL),
		('exhausted', 'bus', 'R4', 'x', now(),                       5, NULL,  NULL),
		('held',      'bus', 'R5', 'x', now(),                       1, NULL,  now() + interval '1 minute'),
		('expired',   'bus', 'R6', 'x', now(),                       1, NULL,  now() - interval '1 minute')`); err != nil {
		t.Fatal(err)
	}
	a := &recordingAlerter{}
	n, err := drainRouteAlertOutbox(ctx, pool, a)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 || len(a.sent) != 2 || a.sent[0] != "bus/R1" || a.sent[1] != "bus/R6" {
		t.Fatalf("sent %v (n=%d), want the fresh row and the one whose claim expired", a.sent, n)
	}
	again := &recordingAlerter{}
	if _, err := drainRouteAlertOutbox(ctx, pool, again); err != nil {
		t.Fatal(err)
	}
	if len(again.sent) != 0 {
		t.Fatalf("second drain sent %v, want nothing: processed rows never resend", again.sent)
	}
}

func TestPruneRouteAlertOutboxKeepsTheDedupeWindow(t *testing.T) {
	pool := outboxTestPool(t)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `
		INSERT INTO route_alert_outbox (dedupe_key, route_type, route_key, body, created_at) VALUES
		('week-old', 'bus', 'R1', 'x', now() - interval '8 days'),
		('day-old',  'bus', 'R2', 'x', now() - interval '2 days')`); err != nil {
		t.Fatal(err)
	}
	if err := pruneRouteAlertOutbox(ctx, pool); err != nil {
		t.Fatal(err)
	}
	var left []string
	rows, err := pool.Query(ctx, `SELECT dedupe_key FROM route_alert_outbox ORDER BY dedupe_key`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			t.Fatal(err)
		}
		left = append(left, k)
	}
	if len(left) != 1 || left[0] != "day-old" {
		t.Fatalf("left %v, want only the row inside the retention window", left)
	}
}
