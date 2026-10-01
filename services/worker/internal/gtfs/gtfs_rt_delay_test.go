package gtfs

import (
	"testing"
	"time"

	"github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
)

func TestBuildGTFSRTDelays(t *testing.T) {
	now := time.Date(2026, 8, 7, 9, 0, 0, 0, pipeline.Taipei)
	index := map[string]railDelayTrip{
		"123": {tripID: "TRA:123:20260807", stations: map[string]bool{"1000": true, "1010": true}},
		"456": {tripID: "TRA:456:20260807", stations: map[string]bool{"2000": true}},
	}
	minutes := map[string]string{
		"123": "7",   // late, station on the train's route
		"456": "0",   // on time
		"789": "5",   // not running today
		"321": "3",   // running, but the station is not one of its calls
		"999": "n/a", // unparseable
	}
	index["321"] = railDelayTrip{tripID: "TRA:321:20260807", stations: map[string]bool{"3000": true}}
	stations := map[string]string{"123": "1010", "456": "2000", "789": "4000", "321": "9999", "999": "1000"}

	entities, stats := buildGTFSRTRailDelays(index, minutes, stations, now)

	if len(entities) != 1 {
		t.Fatalf("emitted %d updates, want 1: %v", len(entities), entities)
	}
	got := entities[0]
	if got.GetId() != "TRA:123:20260807" {
		t.Errorf("entity id = %q", got.GetId())
	}
	trip := got.GetTripUpdate().GetTrip()
	if trip.GetTripId() != "TRA:123:20260807" || trip.GetStartDate() != "20260807" {
		t.Errorf("trip = %v", trip)
	}
	if trip.GetScheduleRelationship() != gtfs.TripDescriptor_SCHEDULED {
		t.Errorf("schedule_relationship = %v, want SCHEDULED", trip.GetScheduleRelationship())
	}
	updates := got.GetTripUpdate().GetStopTimeUpdate()
	if len(updates) != 1 {
		t.Fatalf("%d stop time updates, want 1", len(updates))
	}
	if updates[0].GetStopId() != "TRA:1010:platform" {
		t.Errorf("stop_id = %q, want the platform the calls reference", updates[0].GetStopId())
	}
	if delay := updates[0].GetArrival().GetDelay(); delay != 7*60 {
		t.Errorf("delay = %d seconds, want %d: minutes must be converted", delay, 7*60)
	}
	if updates[0].Departure != nil {
		t.Errorf("departure stated: GTFS-RT already reads it as carrying the arrival's delay")
	}

	want := gtfsRTRailDelayStats{delaysRead: 5, delaysOnTime: 1, trainNotToday: 1, stationUnknown: 1, updates: 1}
	if stats != want {
		t.Errorf("stats = %+v, want %+v", stats, want)
	}
}
