package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/robfig/cron/v3"
)

type workerNativeGTFSQueryTrace struct {
	mu        sync.Mutex
	deadlines []time.Time
}

func (trace *workerNativeGTFSQueryTrace) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	if strings.HasPrefix(data.SQL, "SELECT run_id FROM static_release") {
		deadline, _ := ctx.Deadline()
		trace.mu.Lock()
		trace.deadlines = append(trace.deadlines, deadline)
		trace.mu.Unlock()
	}
	return ctx
}
func (*workerNativeGTFSQueryTrace) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func TestWorkerNativeGTFSCronBoundsIndexReadToOneMinute(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL required")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	t.Cleanup(cancel)
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	schema := fmt.Sprintf("quality_rt_budget_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+quoted+";CREATE TABLE "+quoted+".static_release(run_id text,build_seq bigint)"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		if _, err := admin.Exec(cleanup, "DROP SCHEMA "+quoted+" CASCADE"); err != nil {
			t.Errorf("owned GTFS budget schema cleanup: %v", err)
		}
	})
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	trace := new(workerNativeGTFSQueryTrace)
	config.ConnConfig.Tracer = trace
	config.ConnConfig.RuntimeParams["search_path"] = schema
	db, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	workerContractHealth(t, filepath.Join(t.TempDir(), "healthy"))
	r := cron.New(cron.WithSeconds())
	registerGTFSRTCron(r, db, workerContractRedis(t))
	entries := r.Entries()
	if len(entries) != 1 {
		t.Fatalf("scheduled GTFS entries=%d", len(entries))
	}
	before := time.Now()
	entries[0].Job.Run()
	after := time.Now()
	trace.mu.Lock()
	deadlines := append([]time.Time(nil), trace.deadlines...)
	trace.mu.Unlock()
	if len(deadlines) == 0 {
		t.Fatal("registered GTFS job did not reach the published-index query")
	}
	for _, deadline := range deadlines {
		if deadline.Before(before.Add(time.Minute)) || deadline.After(after.Add(time.Minute)) {
			t.Fatalf("scheduled index query exceeded the one-minute rebuild budget: %v", deadline)
		}
	}
}
