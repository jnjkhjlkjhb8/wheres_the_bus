package bus

import (
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
)

func loopStop(seq uint8) busmodel.StationMap {
	return busmodel.StationMap{
		SubRouteUID: "TAO2610", StopUID: "TAO-stop", StopSequence: seq,
		Destination: "桃園公車站", TurnaroundSequence: 4, TurnaroundName: "銘傳設計大樓",
	}
}

func TestRouteViews(t *testing.T) {
	cases := []struct {
		name string
		stop busmodel.StationMap
		want []uint8
	}{
		{"not split", busmodel.StationMap{StopSequence: 9}, []uint8{0}},
		{"before the turnaround", loopStop(3), []uint8{0}},
		{"the turnaround", loopStop(4), []uint8{0, 1}},
		{"after the turnaround", loopStop(5), []uint8{1}},
	}
	for _, c := range cases {
		views := routeViews(c.stop)
		if len(views) != len(c.want) {
			t.Errorf("%s: %d views, want %d", c.name, len(views), len(c.want))
			continue
		}
		for i, v := range views {
			if v.Direction != c.want[i] || v.StopSequence != c.stop.StopSequence || v.StopUID != c.stop.StopUID {
				t.Errorf("%s: view %d = dir %d seq %d, want dir %d keeping the stop", c.name, i, v.Direction, v.StopSequence, c.want[i])
			}
		}
	}
}

func TestStationView(t *testing.T) {
	cases := []struct {
		name     string
		stop     busmodel.StationMap
		wantDir  uint8
		wantDest string
	}{
		{"not split", busmodel.StationMap{Destination: "終點", StopSequence: 9}, 0, "終點"},
		{"before the turnaround", loopStop(3), 0, "銘傳設計大樓"},
		{"the turnaround", loopStop(4), 1, "桃園公車站"},
		{"after the turnaround", loopStop(5), 1, "桃園公車站"},
	}
	for _, c := range cases {
		v := stationView(c.stop)
		if v.Direction != c.wantDir || v.Destination != c.wantDest {
			t.Errorf("%s: got dir %d → %q, want dir %d → %q", c.name, v.Direction, v.Destination, c.wantDir, c.wantDest)
		}
	}
}

func TestResolveStopServesTurnaroundUnderBothDirections(t *testing.T) {
	now := time.Date(2026, 11, 4, 9, 0, 0, 0, time.FixedZone("Asia/Taipei", 8*60*60))
	b := loopStop(4)
	b.StationUID, b.GroupUID = "station", "group"
	r := &busCitySnapshot{
		city: "Taoyuan", now: now,
		stations:  map[string]*models.Bus_StationArrival{},
		routes:    map[string]*models.Bus_RouteArrival{},
		etamap:    map[etaKey]busmodel.RawEstimated{{"TAO2610", 0, "TAO-stop"}: {StopStatus: 0, EstimatedTime: 120, SrcUpdateTime: now.Format(time.RFC3339)}},
		busmap:    map[string][]*models.BusPosition{},
		atStopMap: map[busAtStopKey]stopPresence{},
	}
	r.resolveStop(b)

	stops := r.routes["TAO2610"].Stops
	if len(stops) != 2 || stops[0].Direction != 0 || stops[1].Direction != 1 || stops[1].StopSequence != 4 {
		t.Fatalf("route stops = %v, want the turnaround under direction 0 and 1", stops)
	}
	if len(r.arrivalEvents) != 2 || r.arrivalEvents[0].Direction != "0" || r.arrivalEvents[1].Direction != "1" {
		t.Fatalf("arrival events = %v, want one per served direction", r.arrivalEvents)
	}
	station := r.stations["group"].Routes
	if len(station) != 1 || station[0].Direction != 1 || station[0].Destination != "桃園公車站" {
		t.Fatalf("station rows = %v, want one row heading back", station)
	}
}
