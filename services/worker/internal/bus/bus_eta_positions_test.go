package bus

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

// taipeiStopStore serves one Taipei stop and clears the process-wide static map
// cache around the test, so every run loads its stops from this store.
func taipeiStopStore(t *testing.T) *fakeBusEtaStore {
	t.Helper()
	prefix := busmodel.CityPrefix["Taipei"]
	predict.StaticMapCache().Delete(prefix)
	t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
	return &fakeBusEtaStore{stops: []busmodel.StationMap{{
		StationUID: "STATION1", StationName: "站牌一", SubRouteUID: "TPE1",
		SubRouteName: "一路", StopUID: "STOP1", StopSequence: 1,
	}}}
}

// positionFailingFetch answers the Taipei position feed with fetchErr and every
// other feed from src.
func positionFailingFetch(src *fakeLiveSource, sink *captureLiveSink, fetchErr error) pipeline.BoundFetch {
	bound := pipeline.BindFetch(src, sink, busTestSpec())
	return func(ctx context.Context, url, name string) (*shared.TDXFetch, error) {
		if fetchErr != nil && name == "bus_RealTimeByFrequencyTaipei" {
			return nil, fetchErr
		}
		return bound(ctx, url, name)
	}
}

func TestBusCityPublishesETAWhenTDXPositionsFail(t *testing.T) {
	tests := []struct {
		name      string
		positions []byte
		fetchErr  error
	}{
		{name: "malformed position payload", positions: []byte(`[{"PlateNumb":"A"},{"PlateNumb":`)},
		{name: "position fetch error", fetchErr: errors.New("exchange TDX token: connection refused")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fixtures := map[string][]byte{"bus_EstimatedTimeOfArrivalTaipei": []byte(`[]`)}
			if tt.positions != nil {
				fixtures["bus_RealTimeByFrequencyTaipei"] = tt.positions
			}
			src := &fakeLiveSource{fixtures: fixtures}
			sink := &captureLiveSink{}
			store := taipeiStopStore(t)
			job := busLiveJob{
				fetch: positionFailingFetch(src, sink, tt.fetchErr), sink: sink, store: store,
				now: time.Now,
			}

			if err := job.runCity(context.Background(), "Taipei"); err != nil {
				t.Fatalf("runCity = %v, want the ETA to publish without positions", err)
			}
			if sink.setFor(shared.BusRouteEtaKey("TPE1")) == nil {
				t.Fatal("route snapshot was not published")
			}
			if len(src.acked) != 1 || src.acked[0] != "bus_EstimatedTimeOfArrivalTaipei" {
				t.Fatalf("acked feeds = %v, want only the ETA feed", src.acked)
			}
			if sink.setFor(shared.BusPositionRawKey("Taipei")) != nil {
				t.Fatal("failed position feed reached the raw cache")
			}
			if sink.setFor(shared.BusCityPublishedKey("Taipei")) == nil {
				t.Fatal("published marker missing after a publish without positions")
			}
			if store.predictionCalls != 1 {
				t.Fatalf("history saves = %d, want 1 for a modified ETA feed", store.predictionCalls)
			}
		})
	}
}

// TestBusETACacheMissInvalidatesOnlyUnmodifiedFeeds covers the failed publish
// when the ETA 304 has no cached rows: every unmodified marker is cleared for a
// full fetch next tick, a modified or dropped position feed is left alone, and
// the published marker is not written.
func TestBusETACacheMissInvalidatesOnlyUnmodifiedFeeds(t *testing.T) {
	tests := []struct {
		name            string
		positions       []byte
		positionsCached bool
		fetchErr        error
		wantInvalidated []string
	}{
		{name: "positions dropped", fetchErr: errors.New("positions down"), wantInvalidated: []string{"bus_EstimatedTimeOfArrivalTaipei"}},
		{name: "positions modified", positions: []byte(`[]`), wantInvalidated: []string{"bus_EstimatedTimeOfArrivalTaipei"}},
		{name: "positions unmodified", positionsCached: true, wantInvalidated: []string{"bus_EstimatedTimeOfArrivalTaipei", "bus_RealTimeByFrequencyTaipei"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fixtures := map[string][]byte{}
			if tt.positions != nil {
				fixtures["bus_RealTimeByFrequencyTaipei"] = tt.positions
			}
			cached := map[string]string{}
			if tt.positionsCached {
				cached[shared.BusPositionRawKey("Taipei")] = `[]`
			}
			src := &fakeLiveSource{fixtures: fixtures}
			sink := &captureLiveSink{strings: cached}
			job := busLiveJob{
				fetch: positionFailingFetch(src, sink, tt.fetchErr), sink: sink, store: taipeiStopStore(t),
				now: time.Now,
			}

			if err := job.runCity(context.Background(), "Taipei"); !errors.Is(err, errBusFeedCacheMiss) {
				t.Fatalf("runCity = %v, want %v", err, errBusFeedCacheMiss)
			}
			if !slices.Equal(src.invalidated, tt.wantInvalidated) {
				t.Fatalf("invalidated feeds = %v, want %v", src.invalidated, tt.wantInvalidated)
			}
			if sink.setFor(shared.BusCityPublishedKey("Taipei")) != nil {
				t.Fatal("published marker written for a city that did not publish")
			}
		})
	}
}

func TestBusDataTaipeiCityMakesNoTDXFetch(t *testing.T) {
	tests := []struct {
		name     string
		vehicles vehicleSource
	}{
		{name: "vehicles available", vehicles: stubVehicleSource{rows: []busmodel.RawPosition{{SubRouteUID: "TPE1", PlateNumb: "757-FW"}}}},
		{name: "vehicle feed down", vehicles: stubVehicleSource{err: errors.New("blob unreachable")}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sink := &captureLiveSink{}
			job := busLiveJob{
				fetch: func(_ context.Context, url, _ string) (*shared.TDXFetch, error) {
					t.Fatalf("Data.taipei city fetched TDX %s", url)
					return nil, nil
				},
				sink: sink, store: taipeiStopStore(t), now: time.Now,
				vehicles: map[string]vehicleSource{"Taipei": tt.vehicles},
				eta:      map[string]etaSource{"Taipei": stubEtaSource{rows: []busmodel.RawEstimated{}}},
			}

			if err := job.runCity(context.Background(), "Taipei"); err != nil {
				t.Fatalf("runCity = %v", err)
			}
			if sink.setFor(shared.BusRouteEtaKey("TPE1")) == nil {
				t.Fatal("route snapshot was not published")
			}
		})
	}
}

func TestDropCityPositionsForgetsPartialFeed(t *testing.T) {
	f := &busCityFeeds{
		posit:         []busmodel.RawPosition{{PlateNumb: "HALF"}},
		positionRaw:   []byte(`[{"PlateNumb":"HALF"}]`),
		positionFetch: &shared.TDXFetch{Modified: true},
	}

	dropCityPositions("Taipei", f, errors.New("decode"))

	if f.posit == nil || len(f.posit) != 0 || f.positionRaw != nil || f.positionFetch != nil {
		t.Fatalf("feeds after drop = posit %+v raw %q fetch %+v, want all positions forgotten", f.posit, f.positionRaw, f.positionFetch)
	}
}
