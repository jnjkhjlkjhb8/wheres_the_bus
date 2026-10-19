package bus

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/weather"
)

func TestBusWeatherSnapshotAcceptsValidAndIgnoresMissingOrInvalidData(t *testing.T) {
	body, err := json.Marshal(weather.Data{Temperature: 22, Humidity: 70, Precipitation: 2, WindSpeed: 3})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		raw   string
		err   error
		valid bool
	}{{string(body), nil, true}, {"bad", nil, false}, {"", errors.New("Redis unavailable"), false}} {
		job := busLiveJob{sink: &readErrorBusSink{value: tc.raw, err: tc.err}}
		got := job.cityWeather(t.Context(), "Taipei")
		if (got != nil) != tc.valid {
			t.Fatalf("weather %q=%v", tc.raw, got)
		}
		if got != nil && (got.Temperature != 22 || got.Humidity != 70 || got.Precipitation != 2 || got.WindSpeed != 3) {
			t.Fatalf("weather=%+v", got)
		}
	}
}

func TestUnwatchedBusCityRefreshesTTLAndPropagatesFailure(t *testing.T) {
	ctx := context.Background()
	sink := &captureLiveSink{}
	if !pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
		t.Fatal("first cold-city visit skipped")
	}
	sentinel := errors.New("refresh failed")
	sink.refreshErr = sentinel
	job := busLiveJob{sink: sink, demandDataset: "bus_eta"}
	if err := job.runDemandCity(ctx, "YilanCounty"); !errors.Is(err, sentinel) {
		t.Fatalf("refresh cause=%v", err)
	}
	sink.refreshErr = nil
	if err := job.runDemandCity(ctx, "YilanCounty"); err != nil {
		t.Fatal(err)
	}
	if len(sink.refresh) != 2 {
		t.Fatalf("refresh calls=%d", len(sink.refresh))
	}
}

func TestFastBusTickReturnsDatabaseFailureBeforeFetchingUpstream(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL required")
	}
	db, err := pgxpool.New(t.Context(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	for _, city := range _busEtaFastCities {
		prefix := busmodel.CityPrefix[city]
		predict.StaticMapCache().Delete(prefix)
		t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
	}
	fetch := func(context.Context, string, string) (*shared.TDXFetch, error) {
		t.Error("failed static query reached upstream")
		return nil, errors.New("unexpected upstream")
	}
	if err := EtaFast(t.Context(), fetch, &captureLiveSink{}, db, nil); err == nil {
		t.Fatal("closed database was accepted")
	}
}

func TestStopEventArchiveCanRemainDisabled(t *testing.T) {
	closeArchive, err := history.Init(t.Context(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := closeArchive(); err != nil {
			t.Error(err)
		}
	}()
	if history.Target() != nil {
		t.Fatal("disabled archive allocated a writer")
	}
	store := pgBusEtaStore{}
	store.saveStopEvents(t.Context(), nil)
	store.saveStopEvents(t.Context(), [][]any{{"plate", "Taipei", "route", int16(0), "stop"}})
}
