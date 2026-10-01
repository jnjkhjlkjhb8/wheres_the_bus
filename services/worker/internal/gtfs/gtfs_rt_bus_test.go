package gtfs

import (
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
)

// busTestMidnight is the service day every case below is expressed against.
func busTestMidnight() time.Time {
	return time.Date(2026, 8, 7, 0, 0, 0, 0, pipeline.Taipei)
}

// atClock returns the unix instant of a HH:MM on the test's service day.
func atClock(hour, minute int) int64 {
	return busTestMidnight().Add(time.Duration(hour)*time.Hour + time.Duration(minute)*time.Minute).Unix()
}

// TestMatchBusVehiclesIsInjectiveAndOrdered covers the assignment rule: buses do
// not overtake, so the nth vehicle out is running the nth departure, and neither
// side may be consumed twice.
func TestMatchBusVehiclesIsInjectiveAndOrdered(t *testing.T) {
	trips := []gtfsRTTrip{
		{tripID: "T:0800", departure: 8 * 60},
		{tripID: "T:0830", departure: 8*60 + 30},
		{tripID: "T:0900", departure: 9 * 60},
	}
	// Two vehicles, each a few minutes late. Order alone would be enough here;
	// the point is that neither claims the other's trip.
	vehicles := []gtfsRTVehicle{
		{plate: "B", projected: atClock(8, 34)},
		{plate: "A", projected: atClock(8, 3)},
	}
	got := matchBusVehicles(vehicles, trips, busTestMidnight())
	if len(got) != 2 {
		t.Fatalf("matched %d, want 2: %v", len(got), got)
	}
	if got["T:0800"].plate != "A" || got["T:0830"].plate != "B" {
		t.Errorf("assignment = %v, want A on 08:00 and B on 08:30", got)
	}
}

// TestMatchBusVehiclesRefusesOutsideWindow asserts a vehicle whose projected
// departure is nowhere near a scheduled one is left alone rather than forced
// onto the nearest.
func TestMatchBusVehiclesRefusesOutsideWindow(t *testing.T) {
	trips := []gtfsRTTrip{{tripID: "T:0800", departure: 8 * 60}}
	vehicles := []gtfsRTVehicle{{plate: "A", projected: atClock(10, 0)}}
	if got := matchBusVehicles(vehicles, trips, busTestMidnight()); len(got) != 0 {
		t.Errorf("matched %v, want nothing: two hours out is not a late bus", got)
	}
}

// TestMatchBusVehiclesPrefersTheNearerDeparture covers the case order alone gets
// wrong: one vehicle running, and it is the second departure's, not the first's.
func TestMatchBusVehiclesPrefersTheNearerDeparture(t *testing.T) {
	trips := []gtfsRTTrip{
		{tripID: "T:0800", departure: 8 * 60},
		{tripID: "T:0815", departure: 8*60 + 15},
	}
	vehicles := []gtfsRTVehicle{{plate: "A", projected: atClock(8, 14)}}
	got := matchBusVehicles(vehicles, trips, busTestMidnight())
	if len(got) != 1 || got["T:0815"].plate != "A" {
		t.Errorf("assignment = %v, want A on 08:15", got)
	}
}

// TestBuildGTFSRTBusDelaysGatesAndEmits runs the whole producer over two
// subroutes: one whose vehicle is unambiguous and matchable, one whose plate is
// claimed by a sibling subroute and must be dropped whole.
func TestBuildGTFSRTBusDelaysGatesAndEmits(t *testing.T) {
	key := gtfsRTRouteKey{subRouteUID: "R1", direction: 0}
	offsets := map[gtfsRTRouteKey]map[string]int64{
		key:                               {"S1": 0, "S2": 300, "S3": 600},
		{subRouteUID: "R2", direction: 0}: {"S9": 0, "S8": 120},
		{subRouteUID: "R3", direction: 0}: {"S9": 0, "S8": 120},
	}
	running := map[gtfsRTRouteKey][]gtfsRTTrip{
		key:                               {{tripID: "R1:0:0800:W:1111111", departure: 8 * 60}},
		{subRouteUID: "R2", direction: 0}: {{tripID: "R2:0:0800:W:1111111", departure: 8 * 60}},
		{subRouteUID: "R3", direction: 0}: {{tripID: "R3:0:0800:W:1111111", departure: 8 * 60}},
	}
	// AAA-1 runs R1 and only R1: projected departure 08:02 from both calls.
	// SHARED runs R2 and R3 at once, which is what a route-level feed looks like
	// when it fans one vehicle across sibling subroutes.
	arrivals := map[string]*models.Bus_RouteArrival{
		"R1": {SubRouteUid: "R1", Stops: []*models.Bus_RouteEstimate{
			{StopUid: "S2", StopSequence: 2, Direction: 0, PlateNumb: "AAA-1", ArrivalUnix: atClock(8, 7)},
			{StopUid: "S3", StopSequence: 3, Direction: 0, PlateNumb: "AAA-1", ArrivalUnix: atClock(8, 12)},
		}},
		"R2": {SubRouteUid: "R2", Stops: []*models.Bus_RouteEstimate{
			{StopUid: "S9", StopSequence: 1, Direction: 0, PlateNumb: "SHARED", ArrivalUnix: atClock(8, 0)},
			{StopUid: "S8", StopSequence: 2, Direction: 0, PlateNumb: "SHARED", ArrivalUnix: atClock(8, 2)},
		}},
		"R3": {SubRouteUid: "R3", Stops: []*models.Bus_RouteEstimate{
			{StopUid: "S9", StopSequence: 1, Direction: 0, PlateNumb: "SHARED", ArrivalUnix: atClock(8, 0)},
			{StopUid: "S8", StopSequence: 2, Direction: 0, PlateNumb: "SHARED", ArrivalUnix: atClock(8, 2)},
		}},
	}

	entities, stats := buildGTFSRTBusDelays(running, arrivals, offsets, busTestMidnight().Add(8*time.Hour))

	if len(entities) != 1 {
		t.Fatalf("emitted %d updates, want 1: %v", len(entities), entities)
	}
	update := entities[0].GetTripUpdate()
	if got := entities[0].GetId(); got != "R1:0:0800:W:1111111" {
		t.Errorf("entity id = %q", got)
	}
	if got := update.GetVehicle().GetId(); got != "AAA-1" {
		t.Errorf("vehicle = %q, want the plate", got)
	}
	calls := update.GetStopTimeUpdate()
	if len(calls) != 2 {
		t.Fatalf("%d stop time updates, want 2", len(calls))
	}
	if calls[0].GetStopId() != "S2" || calls[1].GetStopId() != "S3" {
		t.Errorf("stops = %q,%q, want S2 then S3 in sequence order",
			calls[0].GetStopId(), calls[1].GetStopId())
	}
	if calls[0].StopSequence != nil {
		t.Error("stop_sequence stated: the feed renumbers it, so the live value is not the feed's")
	}
	if got := calls[0].GetArrival().GetTime(); got != atClock(8, 7) {
		t.Errorf("arrival = %d, want the absolute predicted time %d", got, atClock(8, 7))
	}
	if stats.matched != 1 || stats.plateAmbiguous != 2 {
		t.Errorf("stats = %+v, want 1 matched and 2 dropped for an ambiguous plate", stats)
	}
}

func TestBusStopTimeUpdatesClampBackwardsTimes(t *testing.T) {
	vehicle := gtfsRTVehicle{calls: []gtfsRTCall{
		{stopUID: "S1", sequence: 1, arrival: atClock(8, 10)},
		{stopUID: "S2", sequence: 2, arrival: atClock(8, 4)},
		{stopUID: "S3", sequence: 3, arrival: atClock(8, 20)},
	}}
	got := busStopTimeUpdates(vehicle)
	want := []int64{atClock(8, 10), atClock(8, 10), atClock(8, 20)}
	for i, update := range got {
		if update.GetArrival().GetTime() != want[i] {
			t.Errorf("call %d arrival = %d, want %d", i, update.GetArrival().GetTime(), want[i])
		}
	}
}
