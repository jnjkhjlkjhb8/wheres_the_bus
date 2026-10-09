package bus

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

func TestDataTaipeiRawPositions(t *testing.T) {
	buses := []dataTaipeiBus{
		{
			BusID: "757-FW", RouteID: "11202", GoBack: "1",
			Longitude: "121.500962", Latitude: "25.090732",
			Speed: "23", Azimuth: "314", DutyStatus: "2", BusStatus: "0",
			DataTime: "2026-08-06 11:20:40",
		},
		// Direction 未知: no canonical subroute can be derived, so it is dropped.
		{BusID: "730-FW", RouteID: "10283", GoBack: "2", Longitude: "121.5", Latitude: "25.0"},
		// Unplaceable coordinate: dropped rather than published at (0, 0).
		{BusID: "001-AA", RouteID: "10283", GoBack: "0", Longitude: "", Latitude: ""},
	}
	events := []dataTaipeiEvent{
		{BusID: "757-FW", StopID: "18620", CarOnStop: "1"},
		// Already pulled out of the stop: carries no location.
		{BusID: "999-ZZ", StopID: "18621", CarOnStop: "0"},
	}

	seats := []dataTaipeiSeat{
		{BusID: "757-FW", Level: intPtr(2)},
		// A null reading stays missing rather than decoding to 0 (舒適).
		{BusID: "730-FW", Level: nil},
	}

	got := dataTaipeiRawPositions("TPE", buses, events, seats)

	if len(got) != 1 {
		t.Fatalf("positions = %d rows, want 1: %+v", len(got), got)
	}
	p := got[0]
	if p.SubRouteUID != "TPE11202" {
		t.Errorf("SubRouteUID = %q, want TPE11202", p.SubRouteUID)
	}
	if p.StopUID != "TPE18620" {
		t.Errorf("StopUID = %q, want TPE18620", p.StopUID)
	}
	if p.PlateNumb != "757-FW" {
		t.Errorf("PlateNumb = %q, want 757-FW", p.PlateNumb)
	}
	if p.Direction != 1 {
		t.Errorf("Direction = %d, want 1", p.Direction)
	}
	if p.BusPosition.PositionLon != 121.500962 || p.BusPosition.PositionLat != 25.090732 {
		t.Errorf("position = (%v, %v), want (121.500962, 25.090732)",
			p.BusPosition.PositionLon, p.BusPosition.PositionLat)
	}
	if p.Speed != 23 || p.Azimuth != 314 {
		t.Errorf("speed/azimuth = %v/%v, want 23/314", p.Speed, p.Azimuth)
	}
	if p.DutyStatus != 2 || p.BusStatus != 0 {
		t.Errorf("duty/bus status = %d/%d, want 2/0", p.DutyStatus, p.BusStatus)
	}
	if parseGPSTimeUnix(p.GPSTime) == 0 {
		t.Errorf("GPSTime %q does not parse", p.GPSTime)
	}
	if p.CrowdLevel != models.BusCrowdLevel_BUS_CROWD_CROWDED {
		t.Errorf("CrowdLevel = %v, want CROWDED", p.CrowdLevel)
	}
}

func intPtr(v int) *int { return &v }

func TestDataTaipeiCrowdLevel(t *testing.T) {
	tests := []struct {
		name  string
		level *int
		want  models.BusCrowdLevel
		ok    bool
	}{
		{"comfortable", intPtr(0), models.BusCrowdLevel_BUS_CROWD_COMFORTABLE, true},
		{"normal", intPtr(1), models.BusCrowdLevel_BUS_CROWD_NORMAL, true},
		{"crowded", intPtr(2), models.BusCrowdLevel_BUS_CROWD_CROWDED, true},
		// 33 of 1,541 vehicles publish null; an undocumented band is the same
		// situation — a reading we cannot label.
		{"null reading", nil, models.BusCrowdLevel_BUS_CROWD_UNKNOWN, false},
		{"undocumented band", intPtr(9), models.BusCrowdLevel_BUS_CROWD_UNKNOWN, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := dataTaipeiCrowdLevel(tt.level)
			if got != tt.want || ok != tt.ok {
				t.Errorf("dataTaipeiCrowdLevel() = %v, %v; want %v, %v", got, ok, tt.want, tt.ok)
			}
		})
	}
}

func TestMergeDataTaipeiPositions(t *testing.T) {
	tdx := []busmodel.RawPosition{
		{SubRouteUID: "TPE11202", Direction: 1, PlateNumb: ""},
		{SubRouteUID: "TPE11202", Direction: 0, PlateNumb: ""},
		{SubRouteUID: "TPE99999", Direction: 0, PlateNumb: ""},
	}
	fresh := []busmodel.RawPosition{
		{SubRouteUID: "TPE11202", Direction: 1, PlateNumb: "757-FW"},
	}

	got := mergeDataTaipeiPositions(tdx, fresh)

	// The covered direction comes from Data.taipei alone; the other direction and
	// the subroute it never reported keep their TDX rows.
	if len(got) != 3 {
		t.Fatalf("merged = %d rows, want 3: %+v", len(got), got)
	}
	for _, p := range got {
		if p.SubRouteUID == "TPE11202" && p.Direction == 1 && p.PlateNumb != "757-FW" {
			t.Errorf("TDX row survived for a covered subroute direction: %+v", p)
		}
	}
}

func TestMergeDataTaipeiPositionsEmptyKeepsTDX(t *testing.T) {
	tdx := []busmodel.RawPosition{{SubRouteUID: "TPE11202", Direction: 1}}
	if got := mergeDataTaipeiPositions(tdx, nil); len(got) != 1 {
		t.Fatalf("merged = %d rows, want the 1 TDX row back", len(got))
	}
}

func TestDataTaipeiStopStatus(t *testing.T) {
	tests := []struct {
		name         string
		estimateTime string
		wantStatus   uint8
		wantSeconds  int32
		wantOk       bool
	}{
		{"live countdown", "180", 0, 180, true},
		{"not yet departed", "-1", 1, 0, true},
		{"traffic control", "-2", 2, 0, true},
		{"last bus passed", "-3", 3, 0, true},
		{"not operating today", "-4", 4, 0, true},
		{"undocumented sentinel", "-5", 0, 0, false},
		{"unparseable", "N/A", 0, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			status, seconds, ok := dataTaipeiStopStatus(tt.estimateTime)
			if status != tt.wantStatus || seconds != tt.wantSeconds || ok != tt.wantOk {
				t.Errorf("dataTaipeiStopStatus(%q) = %d, %d, %v; want %d, %d, %v",
					tt.estimateTime, status, seconds, ok, tt.wantStatus, tt.wantSeconds, tt.wantOk)
			}
		})
	}
}

func TestDataTaipeiEstimateDirection(t *testing.T) {
	tests := []struct {
		goBack string
		want   uint8
	}{
		{"0", 0},
		{"1", 1},
		{"2", _busEtaDirectionUnknown},
		{"3", _busEtaDirectionUnknown},
	}
	for _, tt := range tests {
		if got := dataTaipeiEstimateDirection(tt.goBack); got != tt.want {
			t.Errorf("dataTaipeiEstimateDirection(%q) = %d, want %d", tt.goBack, got, tt.want)
		}
	}
}

func TestDataTaipeiRawEstimates(t *testing.T) {
	rows := []dataTaipeiEstimate{
		{RouteID: 11202, StopID: 18620, EstimateTime: "180", GoBack: "1"},
		{RouteID: 11202, StopID: 18621, EstimateTime: "-1", GoBack: "2"},
		// Not one of the documented sentinels: dropped rather than guessed at.
		{RouteID: 11202, StopID: 18622, EstimateTime: "bogus", GoBack: "0"},
	}

	got := dataTaipeiRawEstimates("TPE", rows)

	if len(got) != 2 {
		t.Fatalf("estimates = %d rows, want 2: %+v", len(got), got)
	}
	live := got[0]
	if live.RouteUID != "TPE11202" || live.StopUID != "TPE18620" {
		t.Errorf("RouteUID/StopUID = %q/%q, want TPE11202/TPE18620", live.RouteUID, live.StopUID)
	}
	if live.SubRouteUID != "" {
		t.Errorf("SubRouteUID = %q, want empty (route-level only)", live.SubRouteUID)
	}
	if live.Direction != 1 || live.StopStatus != 0 || live.EstimatedTime != 180 {
		t.Errorf("live entry = direction %d status %d est %d, want 1/0/180",
			live.Direction, live.StopStatus, live.EstimatedTime)
	}
	notDeparted := got[1]
	if notDeparted.Direction != _busEtaDirectionUnknown || notDeparted.StopStatus != 1 {
		t.Errorf("not-departed entry = direction %d status %d, want %d/1",
			notDeparted.Direction, notDeparted.StopStatus, _busEtaDirectionUnknown)
	}
}

// stubEtaSource stands in for the blob feed so the ETA override can be
// exercised without a network call.
type stubEtaSource struct {
	rows []busmodel.RawEstimated
	err  error
}

func (s stubEtaSource) estimates(context.Context) ([]busmodel.RawEstimated, error) {
	return s.rows, s.err
}

func TestRunCityUsesEtaSourceInsteadOfTDX(t *testing.T) {
	now := time.Date(2026, time.July, 10, 9, 0, 0, 0, pipeline.Taipei)
	prefix := busmodel.CityPrefix["Taipei"]
	predict.StaticMapCache().Delete(prefix)
	predict.StoreStaticMapIn(predict.StaticMapCache(), prefix, []busmodel.StationMap{{
		StationUID: "STATION1", StationName: "站牌一", GroupUID: "GROUP1", GroupName: "群組一",
		RouteUID: prefix + "1", SubRouteUID: prefix + "1", SubRouteName: "一路",
		Direction: 0, StopUID: "STOP1", StopSequence: 1,
	}}, "", now)
	t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })

	// A city listed in j.eta must never reach TDX for its ETA: the position
	// fetch is the only TDX call this test expects.
	fetch := func(_ context.Context, _ string, name string) (*shared.TDXFetch, error) {
		if name == "bus_EstimatedTimeOfArrivalTaipei" {
			t.Fatal("TDX ETA fetch called for a city configured with an etaSource")
		}
		return &shared.TDXFetch{
			Decoder: json.NewDecoder(bytes.NewReader([]byte(`[]`))), Modified: true,
			Ack: func() error { return nil }, Close: func() error { return nil },
			Invalidate: func() error { return nil },
		}, nil
	}
	target := &captureBusArrivalNotifier{}
	job := busLiveJob{
		fetch: fetch, sink: &captureLiveSink{}, store: &fakeBusEtaStore{},
		eta: map[string]etaSource{"Taipei": stubEtaSource{rows: []busmodel.RawEstimated{{
			RouteUID: "TPE1", StopUID: "STOP1", Direction: 0, StopStatus: 0, EstimatedTime: 90,
		}}}},
		now: func() time.Time { return now },
	}

	if err := runBusEtaCities(context.Background(), []string{"Taipei"}, &job, target); err != nil {
		t.Fatalf("runBusEtaCities() error = %v", err)
	}
	if target.batches != 1 || len(target.calls) != 1 || target.calls[0].seconds != 90 {
		t.Fatalf("notification batches/calls = %d/%+v, want one arrival at 90s from the eta source",
			target.batches, target.calls)
	}
}

func TestGunzipIfCompressed(t *testing.T) {
	plain := []byte(`{"BusInfo":[]}`)
	got, err := gunzipIfCompressed(plain)
	if err != nil || string(got) != string(plain) {
		t.Fatalf("uncompressed body = %q, %v; want it back unchanged", got, err)
	}
}

func TestBuildBusAtStopMap(t *testing.T) {
	positions := []busmodel.RawPosition{
		{SubRouteUID: "TPE11202", Direction: 1, StopUID: "TPE18620", PlateNumb: "757-FW", Speed: 12},
		// No stop event for this vehicle: it stays out of the index entirely, so
		// its stop keeps whatever nearestBus guessed.
		{SubRouteUID: "TPE11202", Direction: 1, StopUID: "", PlateNumb: "730-FW"},
	}

	index := buildBusAtStopMap("Taipei", positions)

	plate, speed, dist, ok := busAtStop(index, busAtStopKey{"TPE11202", 1, "TPE18620"})
	if !ok {
		t.Fatalf("stop with a reported vehicle resolved nothing")
	}
	if *plate != "757-FW" || *speed != 12 || *dist != 0 {
		t.Errorf("at-stop bus = %q/%d/%d, want 757-FW/12/0", *plate, *speed, *dist)
	}
	if _, _, _, ok := busAtStop(index, busAtStopKey{"TPE11202", 1, "TPE99999"}); ok {
		t.Errorf("stop with no reported vehicle resolved one")
	}
}

func TestBuildBusAtStopMapIgnoresTDXPositions(t *testing.T) {
	// TDX positions never carry a StopUID, so every other city keeps nearestBus.
	positions := []busmodel.RawPosition{{SubRouteUID: "TXG1234", Direction: 0, PlateNumb: "ABC-123"}}
	if index := buildBusAtStopMap("Taichung", positions); len(index) != 0 {
		t.Fatalf("index = %d entries, want 0", len(index))
	}
}

// stubVehicleSource stands in for the blob feed so the overlay can be exercised
// without a network call.
type stubVehicleSource struct {
	rows []busmodel.RawPosition
	err  error
}

func (s stubVehicleSource) positions(context.Context) ([]busmodel.RawPosition, error) {
	return s.rows, s.err
}

func TestOverlayVehicles(t *testing.T) {
	tdx := []busmodel.RawPosition{{SubRouteUID: "TPE11202", Direction: 1}}
	fresh := []busmodel.RawPosition{{SubRouteUID: "TPE11202", Direction: 1, PlateNumb: "757-FW"}}

	tests := []struct {
		name      string
		job       busLiveJob
		city      string
		wantPlate string
	}{
		{
			name:      "covered city takes the richer feed",
			job:       busLiveJob{vehicles: map[string]vehicleSource{dataset.DataTaipeiCity: stubVehicleSource{rows: fresh}}},
			city:      dataset.DataTaipeiCity,
			wantPlate: "757-FW",
		},
		{
			name:      "a second covered city also takes the richer feed",
			job:       busLiveJob{vehicles: map[string]vehicleSource{"NewTaipei": stubVehicleSource{rows: fresh}}},
			city:      "NewTaipei",
			wantPlate: "757-FW",
		},
		{
			name: "other cities are untouched",
			job:  busLiveJob{vehicles: map[string]vehicleSource{dataset.DataTaipeiCity: stubVehicleSource{rows: fresh}}},
			city: "Taichung",
		},
		{
			name: "a failing feed falls back to TDX",
			job:  busLiveJob{vehicles: map[string]vehicleSource{dataset.DataTaipeiCity: stubVehicleSource{err: errors.New("blob unreachable")}}},
			city: dataset.DataTaipeiCity,
		},
		{
			name: "no feed configured stays on TDX",
			job:  busLiveJob{},
			city: dataset.DataTaipeiCity,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.job.overlayVehicles(context.Background(), tt.city, tdx)
			if len(got) != 1 {
				t.Fatalf("positions = %d rows, want 1", len(got))
			}
			if got[0].PlateNumb != tt.wantPlate {
				t.Errorf("PlateNumb = %q, want %q", got[0].PlateNumb, tt.wantPlate)
			}
		})
	}
}
