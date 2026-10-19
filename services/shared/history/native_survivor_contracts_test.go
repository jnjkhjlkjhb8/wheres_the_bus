package history

import (
	"context"
	"errors"
	"fmt"
	"math"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/samber/oops"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestHistoryNativeGreatCircleDistances(t *testing.T) {
	for _, tc := range []struct {
		name                          string
		lat1, lon1, lat2, lon2, angle float64
	}{
		{"meridian", 10, 0, 40, 0, math.Pi / 6},
		{"northern_parallel", 60, 0, 60, 180, math.Pi / 3},
		{"lower_parallel", 30, 0, 30, 180, 2 * math.Pi / 3},
		{"quarter_sphere", 0, 0, 60, 90, math.Pi / 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			want := 6371000 * tc.angle
			got := Haversine(tc.lat1, tc.lon1, tc.lat2, tc.lon2)
			if math.IsNaN(got) || math.Abs(got-want) > 0.000001 {
				t.Fatalf("great-circle distance = %.9f m, want %.9f m", got, want)
			}
		})
	}
}

func TestHistoryNativeSnapshotWindows(t *testing.T) {
	for _, tc := range []struct {
		interval        time.Duration
		inside, outside int64
	}{{BusEtaFastTickInterval, 19, 20}, {BusEtaTickInterval, 29, 30}} {
		if !SnapshotTick(time.Unix(600+tc.inside, 0), tc.interval) || SnapshotTick(time.Unix(600+tc.outside, 0), tc.interval) {
			t.Fatalf("snapshot interval %v has incorrect endpoint", tc.interval)
		}
	}
}

func TestHistoryNativeSubmitUsesProductionBudgets(t *testing.T) {
	saved := _flushes
	owned := &Flusher{queue: make(chan Flush, 8), workers: 1, timeout: saved.timeout}
	_flushes = owned
	t.Cleanup(func() { defer func() { _flushes = saved }(); owned.Close() })
	for _, tc := range []struct {
		rows   int
		budget time.Duration
	}{{1, 60 * time.Second}, {1000, 65 * time.Second}, {2000, 70 * time.Second}} {
		seen := make(chan time.Time, 1)
		before := time.Now()
		Submit("live_archive", tc.rows, func(ctx context.Context) { deadline, _ := ctx.Deadline(); seen <- deadline })
		select {
		case deadline := <-seen:
			after := time.Now()
			if deadline.Before(before.Add(tc.budget)) || deadline.After(after.Add(tc.budget)) {
				t.Fatalf("%d-row deadline %v outside %v..%v", tc.rows, deadline, before.Add(tc.budget), after.Add(tc.budget))
			}
		case <-time.After(5 * time.Second):
			t.Fatal("submitted archive write did not run")
		}
	}
}

func TestHistoryNativeArchiveExactBatchHasNoEmptyWrite(t *testing.T) {
	rows := make([][]any, 1000)
	for i := range rows {
		rows[i] = []any{fmt.Sprintf("row-%d", i)}
	}
	db := &fakeExecer{}
	if err := Insert(context.Background(), db, "live_archive", []string{"dataset"}, rows); err != nil {
		t.Fatal(err)
	}
	if len(db.stmts) != 1 || len(db.args) != 1 || len(db.args[0]) != 1000 {
		t.Fatalf("exact batch issued %d statements with args %v", len(db.stmts), db.args)
	}
	for i, arg := range db.args[0] {
		if arg != fmt.Sprintf("row-%d", i) {
			t.Fatalf("row %d = %v", i, arg)
		}
	}
}

func TestHistoryNativePartitionCountsMatchAddedMonths(t *testing.T) {
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	db := &fakeAdmin{byTable: map[string][]archivePartition{"live_archive": {{name: "p2026_08", upper: month(2026, time.September)}}}}
	if err := MaintainPartitions(context.Background(), db, month(2026, time.August)); err != nil {
		t.Fatal(err)
	}
	entries := logs.FilterMessage("added partitions").All()
	found := false
	for _, entry := range entries {
		fields := entry.ContextMap()
		if fields["table"] == "live_archive" {
			found = true
			if fields["partitions"] != int64(3) {
				t.Fatalf("added months = %v", fields)
			}
		}
	}
	if !found {
		t.Fatal("missing archive partition completion")
	}
}

func TestHistoryNativePartitionFailuresPreserveCauseAndScope(t *testing.T) {
	for _, kind := range []string{"add", "drop"} {
		t.Run(kind, func(t *testing.T) {
			cause := errors.New("partition DDL rejected")
			existing := []archivePartition{{name: "p2026_02", upper: month(2026, time.March)}, {name: "p2026_11", upper: month(2026, time.December)}}
			if kind == "add" {
				existing = []archivePartition{{name: "p2026_08", upper: month(2026, time.September)}}
			}
			db := &fakeAdmin{execErr: cause, byTable: map[string][]archivePartition{"live_archive_bus": existing}}
			core, logs := observer.New(zap.InfoLevel)
			restore := zap.ReplaceGlobals(zap.New(core))
			t.Cleanup(restore)
			err := MaintainPartitions(context.Background(), db, month(2026, time.August))
			if !errors.Is(err, cause) {
				t.Fatalf("failure lost original cause: %v", err)
			}
			success := "added partitions"
			if kind == "drop" {
				success = "dropped partitions"
			}
			if logs.FilterMessage(success).Len() != 0 {
				t.Fatal("failed DDL reported successful partitions")
			}
			var structured oops.OopsError
			if !errors.As(err, &structured) || structured.Context()["table"] != "live_archive_bus" {
				t.Fatalf("failure scope = %v", err)
			}
			want := 1
			if kind == "add" {
				want = 3
			}
			if structured.Context()["partitions"] != want {
				t.Fatalf("affected partitions = %v", structured.Context())
			}
		})
	}
}

type historyNativeReader struct {
	segments      []SegmentObs
	segmentErr    error
	segmentWindow time.Duration
	arrivalValues []arrivalEvent
	arrivalSince  time.Time
}

func (r *historyNativeReader) arrivals(_ context.Context, since time.Time) ([]arrivalEvent, error) {
	r.arrivalSince = since
	return r.arrivalValues, nil
}
func (r *historyNativeReader) segmentsByEstimate(_ context.Context, window time.Duration) ([]SegmentObs, error) {
	r.segmentWindow = window
	return r.segments, r.segmentErr
}

type historyNativeQueryTrace struct {
	mu                sync.Mutex
	segmentBatchSizes []int
}

func (r *historyNativeQueryTrace) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	if strings.Contains(data.SQL, "INSERT INTO bus_segment_time") && len(data.Args) == 6 {
		r.mu.Lock()
		defer r.mu.Unlock()
		r.segmentBatchSizes = append(r.segmentBatchSizes, len(data.Args[0].([]string)))
	}
	return ctx
}
func (*historyNativeQueryTrace) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func historyNativeTracedPool(t *testing.T, base *pgxpool.Pool, tracer *historyNativeQueryTrace) *pgxpool.Pool {
	t.Helper()
	cfg := base.Config()
	cfg.ConnConfig.Tracer = tracer
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestHistoryNativeEstimateWindowAndExactBatchPersistence(t *testing.T) {
	base := predictionPool(t)
	trace := &historyNativeQueryTrace{}
	pool := historyNativeTracedPool(t, base, trace)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, err := pool.Exec(ctx, `CREATE TABLE bus_segment_time (sub_route_uid text NOT NULL, direction smallint NOT NULL, from_stop_uid text NOT NULL, to_stop_uid text NOT NULL, secs int NOT NULL, sample_count int NOT NULL, updated_at timestamptz NOT NULL, PRIMARY KEY(sub_route_uid,direction,from_stop_uid,to_stop_uid))`); err != nil {
		t.Fatal(err)
	}
	hist := &historyNativeReader{segments: make([]SegmentObs, 2000)}
	for i := range hist.segments {
		hist.segments[i] = SegmentObs{SubRouteUID: "native-segments", Direction: 1, fromStopUID: fmt.Sprintf("from-%d", i), toStopUID: fmt.Sprintf("to-%d", i), secs: 120, sampleCount: 3}
	}
	if err := ComputeSegmentTimesFromEstimates(ctx, pool, hist); err != nil {
		t.Fatal(err)
	}
	if hist.segmentWindow != 14*24*time.Hour {
		t.Fatalf("history window = %v", hist.segmentWindow)
	}
	trace.mu.Lock()
	sizes := append([]int(nil), trace.segmentBatchSizes...)
	trace.mu.Unlock()
	if !reflect.DeepEqual(sizes, []int{2000}) {
		t.Fatalf("segment batches = %v", sizes)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM bus_segment_time WHERE direction=1 AND secs=120 AND sample_count=3`).Scan(&n); err != nil || n != 2000 {
		t.Fatalf("persisted segments = %d, %v", n, err)
	}
}

func TestHistoryNativeEstimateReadFailurePreservesCause(t *testing.T) {
	pool := predictionPool(t)
	cause := errors.New("history reader unavailable")
	hist := &historyNativeReader{segmentErr: cause}
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	if err := ComputeSegmentTimesFromEstimates(context.Background(), pool, hist); !errors.Is(err, cause) {
		t.Fatalf("reader failure = %v", err)
	}
	if logs.FilterMessage("complete").Len() != 0 {
		t.Fatal("failed segment read reported completion")
	}
}

func TestHistoryNativeEstimateWriteFailureRetainsBatchRange(t *testing.T) {
	pool := predictionPool(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := pool.Exec(ctx, `CREATE TABLE bus_segment_time (sub_route_uid text, direction smallint, from_stop_uid text, to_stop_uid text, secs int CHECK(secs < 0), sample_count int, updated_at timestamptz, UNIQUE(sub_route_uid,direction,from_stop_uid,to_stop_uid))`); err != nil {
		t.Fatal(err)
	}
	hist := &historyNativeReader{segments: []SegmentObs{{SubRouteUID: "bad", fromStopUID: "a", toStopUID: "b", secs: 120, sampleCount: 3}}}
	err := ComputeSegmentTimesFromEstimates(ctx, pool, hist)
	var structured oops.OopsError
	if !errors.As(err, &structured) || structured.Context()["start"] != 0 || structured.Context()["end"] != 1 {
		t.Fatalf("batch failure range = %v", err)
	}
	var sqlState interface{ SQLState() string }
	if !errors.As(err, &sqlState) || sqlState.SQLState() != "23514" {
		t.Fatalf("constraint cause = %v", err)
	}
}

func TestHistoryNativeDistanceFillPreservesDatabaseFailure(t *testing.T) {
	pool := predictionPool(t)
	pool.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, cause := pool.Exec(ctx, "SELECT 1")
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	err := FillSegmentTimesFromDistance(ctx, pool)
	if cause == nil || !errors.Is(err, cause) {
		t.Fatalf("database failure lost cause: %v / %v", err, cause)
	}
	if logs.FilterMessage("complete").Len() != 0 {
		t.Fatal("failed distance fill reported completion")
	}
}

func TestHistoryNativePredictionWindowAndCompletedGroups(t *testing.T) {
	pool := predictionPool(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	at := time.Now().UTC().Truncate(time.Microsecond)
	preds := []PredictionRecord{{SubRouteUID: "a", StopUID: "s", Source: SourceModel, PredictedAt: at, PredictedSecs: 180}, {SubRouteUID: "a", StopUID: "s", Source: SourceTDX, PredictedAt: at, PredictedSecs: 60}, {SubRouteUID: "b", StopUID: "s", Source: SourceSchedule, PredictedAt: at, PredictedSecs: 90}}
	RecordPredictionErrors(ctx, pool, preds)
	hist := &historyNativeReader{arrivalValues: []arrivalEvent{{SubRouteUID: "a", StopUID: "s", arrivedAt: at.Add(time.Minute)}, {SubRouteUID: "b", StopUID: "s", arrivedAt: at.Add(time.Minute)}}}
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	before := time.Now()
	err := MeasurePredictionError(ctx, pool, hist)
	after := time.Now()
	if err != nil {
		t.Fatal(err)
	}
	if hist.arrivalSince.Before(before.Add(-24*time.Hour)) || hist.arrivalSince.After(after.Add(-24*time.Hour)) {
		t.Fatalf("arrival cutoff = %v", hist.arrivalSince)
	}
	entries := logs.FilterMessage("log").All()
	if len(entries) != 3 {
		t.Fatalf("accuracy groups = %v", entries)
	}
	for i, want := range []struct {
		route, source string
		mae           float64
	}{{"a", SourceModel, 120}, {"a", SourceTDX, 0}, {"b", SourceSchedule, 30}} {
		fields := entries[i].ContextMap()
		if fields["sub_route"] != want.route || fields["source"] != want.source || fields["mae_seconds"] != want.mae || fields["samples"] != int64(1) {
			t.Fatalf("accuracy group %d = %v", i, fields)
		}
	}
	completed := logs.FilterMessage("complete").All()
	if len(completed) != 1 || completed[0].ContextMap()["groups"] != int64(3) {
		t.Fatalf("completed groups = %v", completed)
	}
}

func TestHistoryNativePredictionQueryFailureRetainsCause(t *testing.T) {
	for _, tc := range []struct {
		name string
		hist Reader
	}{{"history_disabled", nil}, {"history_enabled", &historyNativeReader{}}} {
		t.Run(tc.name, func(t *testing.T) {
			pool := predictionPool(t)
			pool.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			t.Cleanup(cancel)
			_, cause := pool.Exec(ctx, "SELECT 1")
			core, logs := observer.New(zap.InfoLevel)
			restore := zap.ReplaceGlobals(zap.New(core))
			t.Cleanup(restore)
			err := MeasurePredictionError(ctx, pool, tc.hist)
			if cause == nil || !errors.Is(err, cause) {
				t.Fatalf("prediction query failure = %v, cause = %v", err, cause)
			}
			if logs.FilterMessage("complete").Len() != 0 {
				t.Fatal("failed prediction query reported completion")
			}
		})
	}
}

func TestHistoryNativePredictionAggregateRowsFailure(t *testing.T) {
	pool := predictionPool(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, statement := range []string{
		`INSERT INTO bus_eta_prediction_error (sub_route_uid, direction, stop_uid, source, predicted_at, predicted_seconds, actual_seconds) VALUES ('fault', 0, 's', 'model', now(), 90, 60)`,
		`ALTER TABLE bus_eta_prediction_error RENAME TO native_prediction_input`,
		`CREATE FUNCTION native_prediction_failure() RETURNS integer LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='22012', MESSAGE='history aggregation fault'; END $$`,
		`CREATE VIEW bus_eta_prediction_error AS SELECT sub_route_uid, source, predicted_at, native_prediction_failure() AS predicted_seconds, actual_seconds FROM native_prediction_input`,
	} {
		if _, err := pool.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	err := MeasurePredictionError(ctx, pool, nil)
	var sqlState interface{ SQLState() string }
	if !errors.As(err, &sqlState) || sqlState.SQLState() != "22012" || !strings.Contains(err.Error(), "history aggregation fault") {
		t.Fatalf("aggregate stream failure = %v", err)
	}
	if logs.FilterMessage("complete").Len() != 0 {
		t.Fatal("failed aggregation reported completion")
	}
}
