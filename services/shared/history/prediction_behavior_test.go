package history

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

type arrivalFixture struct {
	values []arrivalEvent
	err    error
}

func (f arrivalFixture) arrivals(context.Context, time.Time) ([]arrivalEvent, error) {
	return f.values, f.err
}
func (arrivalFixture) segmentsByEstimate(context.Context, time.Duration) ([]SegmentObs, error) {
	return nil, nil
}

func predictionPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	admin := segmentEtaTestPool(t)
	schema := fmt.Sprintf("quality_prediction_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(context.Background(), "CREATE SCHEMA "+quoted); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+quoted+" CASCADE"); admin.Close() })
	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(context.Background(), "CREATE TABLE "+quoted+".bus_eta_prediction_error (LIKE public.bus_eta_prediction_error INCLUDING ALL)"); err != nil {
		t.Fatal(err)
	}
	return pool
}

func TestPredictionPersistenceFillsOnlyMatchingOpenRows(t *testing.T) {
	pool := predictionPool(t)
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Microsecond)
	base := PredictionRecord{SubRouteUID: "route", Direction: 1, StopUID: "stop", Source: SourceModel, PredictedAt: at, PredictedSecs: 200}
	other := base
	other.Source = SourceSchedule
	other.PredictedSecs = 100
	old := base
	old.SubRouteUID = "old"
	old.PredictedAt = at.Add(-25 * time.Hour)
	RecordPredictionErrors(ctx, pool, nil)
	RecordPredictionErrors(ctx, pool, []PredictionRecord{base, other, old})
	records, err := loadOpenPredictions(ctx, pool)
	if err != nil || len(records) != 2 {
		t.Fatalf("open predictions=%v %v", records, err)
	}
	n, err := fillPredictionActuals(ctx, pool, arrivalFixture{values: []arrivalEvent{{SubRouteUID: "route", Direction: 1, StopUID: "stop", arrivedAt: at.Add(2 * time.Minute)}}})
	if err != nil || n != 2 {
		t.Fatalf("fill=%d %v", n, err)
	}
	rows, err := pool.Query(ctx, "SELECT source, actual_seconds FROM bus_eta_prediction_error WHERE sub_route_uid='route' ORDER BY source")
	if err != nil {
		t.Fatal(err)
	}
	actual := map[string]int{}
	for rows.Next() {
		var source string
		var seconds int
		if err := rows.Scan(&source, &seconds); err != nil {
			t.Fatal(err)
		}
		actual[source] = seconds
	}
	rows.Close()
	if !reflect.DeepEqual(actual, map[string]int{SourceModel: 120, SourceSchedule: 120}) {
		t.Fatalf("actual=%v", actual)
	}
	matched := matchPredictionActual([]PredictionRecord{base}, []arrivalEvent{{SubRouteUID: "route", Direction: 1, StopUID: "stop", arrivedAt: at.Add(3 * time.Minute)}}, time.Hour)
	if n, err := writePredictionActuals(ctx, pool, matched); err != nil || n != 0 {
		t.Fatalf("overwrite filled rows=%d %v", n, err)
	}
	if n, err := writePredictionActuals(ctx, nil, nil); err != nil || n != 0 {
		t.Fatalf("empty write=%d %v", n, err)
	}
	if n, err := fillPredictionActuals(ctx, pool, arrivalFixture{}); err != nil || n != 0 {
		t.Fatalf("no open fill=%d %v", n, err)
	}
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	if err := MeasurePredictionError(ctx, pool, nil); err != nil {
		t.Fatal(err)
	}
	summary := logs.FilterMessage("log").All()
	if len(summary) != 2 {
		t.Fatalf("MAE entries=%v", summary)
	}
	for _, entry := range summary {
		fields := entry.ContextMap()
		want := 80.0
		if fields["source"] == SourceSchedule {
			want = 20
		}
		if fields["mae_seconds"] != want || fields["samples"] != int64(1) || fields["sub_route"] != "route" {
			t.Fatalf("MAE=%v", fields)
		}
	}
}

func TestPredictionPersistenceReportsReaderAndDatabaseFailures(t *testing.T) {
	pool := predictionPool(t)
	ctx := context.Background()
	p := PredictionRecord{SubRouteUID: "r", StopUID: "s", Source: SourceTDX, PredictedAt: time.Now().UTC(), PredictedSecs: 10}
	RecordPredictionErrors(ctx, pool, []PredictionRecord{p})
	sentinel := errors.New("archive unavailable")
	if _, err := fillPredictionActuals(ctx, pool, arrivalFixture{err: sentinel}); !errors.Is(err, sentinel) {
		t.Fatalf("reader failure=%v", err)
	}
	if err := MeasurePredictionError(ctx, pool, arrivalFixture{err: sentinel}); !errors.Is(err, sentinel) {
		t.Fatalf("measure reader failure=%v", err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := loadOpenPredictions(canceled, pool); err == nil {
		t.Fatal("canceled query succeeded")
	}
	if _, err := fillPredictionActuals(canceled, pool, arrivalFixture{}); err == nil {
		t.Fatal("canceled fill succeeded")
	}
	if _, err := writePredictionActuals(canceled, pool, []matchedError{{SubRouteUID: "r", StopUID: "s", Source: SourceTDX, PredictedAt: p.PredictedAt, actualSecs: 1}}); err == nil {
		t.Fatal("canceled write succeeded")
	}
	if err := MeasurePredictionError(canceled, pool, nil); err == nil {
		t.Fatal("canceled measure succeeded")
	}
	core, logs := observer.New(zap.ErrorLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	RecordPredictionErrors(canceled, pool, []PredictionRecord{p})
	if logs.FilterMessage("insert predictions error").Len() != 1 {
		t.Fatalf("insert failure logs=%v", logs.All())
	}
}

func TestPredictionArrivalWindowIncludesEndpointsAndPreservesInputs(t *testing.T) {
	at := time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)
	p := PredictionRecord{SubRouteUID: "r", Direction: 1, StopUID: "s", Source: SourceTDX, PredictedAt: at, PredictedSecs: 1}
	for _, offset := range []time.Duration{0, time.Second / 2, 30 * time.Minute, 30*time.Minute + time.Nanosecond} {
		a := []arrivalEvent{{SubRouteUID: "wrong", Direction: 1, StopUID: "s", arrivedAt: at}, {SubRouteUID: "r", Direction: 0, StopUID: "s", arrivedAt: at}, {SubRouteUID: "r", Direction: 1, StopUID: "wrong", arrivedAt: at}, {SubRouteUID: "r", Direction: 1, StopUID: "s", arrivedAt: at.Add(offset)}}
		original := append([]arrivalEvent(nil), a...)
		got := matchPredictionActual([]PredictionRecord{p}, a, 30*time.Minute)
		if !reflect.DeepEqual(a, original) {
			t.Fatal("caller arrivals reordered")
		}
		if offset > 30*time.Minute {
			if len(got) != 0 {
				t.Fatalf("outside window=%v", got)
			}
			continue
		}
		want := int(offset.Round(time.Second).Seconds())
		if len(got) != 1 || got[0].actualSecs != want || got[0].Direction != 1 || got[0].PredictedAt != at {
			t.Fatalf("offset %v=%v", offset, got)
		}
	}
}
