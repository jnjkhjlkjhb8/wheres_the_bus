package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
)

type mrtTickBudgetTrace struct {
	deadline time.Time
	observed bool
}

func (t *mrtTickBudgetTrace) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	if strings.Contains(data.SQL, "SELECT r.reminder_id") {
		t.deadline, t.observed = ctx.Deadline()
	}
	return ctx
}
func (*mrtTickBudgetTrace) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func TestMrtScheduledTickProvidesTwelveSecondDatabaseBudget(t *testing.T) {
	db, _ := riderWorkerTestPool(t)
	if _, err := db.Exec(context.Background(), `ALTER TABLE firebase_arrival_reminder ADD COLUMN reminder_id text, ADD COLUMN install_id text, ADD COLUMN lead_minutes int;
 CREATE TABLE firebase_device(install_id text,fcm_token text,push_enabled boolean)`); err != nil {
		t.Fatal(err)
	}
	trace := &mrtTickBudgetTrace{}
	cfg := db.Config().Copy()
	cfg.ConnConfig.Tracer = trace
	tracked, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(tracked.Close)
	if err := tracked.Ping(context.Background()); err != nil {
		t.Fatal(err)
	}
	old := _health
	_health = nil
	t.Cleanup(func() { _health = old })
	t.Setenv("TRTC_USERNAME", "")
	t.Setenv("TRTC_PASSWORD", "")
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	r := cron.New(cron.WithSeconds())
	registerMrtTrackCron(r, rc, tracked, nil, nil)
	entries := r.Entries()
	if len(entries) != 1 {
		t.Fatalf("tracker scheduler entries=%d", len(entries))
	}
	before := time.Now()
	entries[0].Job.Run()
	after := time.Now()
	if !trace.observed || trace.deadline.Before(before.Add(12*time.Second)) || trace.deadline.After(after.Add(12*time.Second)) {
		t.Fatalf("scheduled query observed=%t deadline=%v bracket=[%v,%v]", trace.observed, trace.deadline, before, after)
	}
}
