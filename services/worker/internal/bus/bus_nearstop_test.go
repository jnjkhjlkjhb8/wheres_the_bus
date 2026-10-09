package bus

import (
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func nearStopAt(now time.Time, offset time.Duration) string {
	return now.Add(offset).Format(time.RFC3339)
}

func TestBuildNearStopIndex(t *testing.T) {
	now := time.Date(2026, 8, 9, 8, 0, 0, 0, pipeline.Taipei)
	arrive := func(plate, stop string, age time.Duration) rawBusNearStop {
		return rawBusNearStop{
			PlateNumb: plate, SubRouteUID: "THB170301", Direction: 0, StopUID: stop,
			A2EventType: _busA2EventArrive, GPSTime: nearStopAt(now, -age),
		}
	}
	offDuty := arrive("OFFDUTY", "S3", 10*time.Second)
	offDuty.DutyStatus = 2
	outOfService := arrive("NOSERVICE", "S4", 10*time.Second)
	outOfService.BusStatus = 99
	departed := arrive("DEPARTED", "S7", 10*time.Second)
	departed.A2EventType = _busA2EventDepart
	rows := []rawBusNearStop{
		arrive("kka-1234", "S1", 20*time.Second),
		arrive("STALE-1", "S2", 30*time.Minute),
		offDuty,
		outOfService,
		{PlateNumb: "NOCLOCK", SubRouteUID: "THB170301", StopUID: "S5", A2EventType: _busA2EventArrive},
		arrive("", "S6", 10*time.Second),
		// A departure says where the bus no longer is.
		departed,
	}
	index := buildNearStopIndex("InterCity", rows, now)
	if len(index) != 1 {
		t.Fatalf("index = %#v, want only the fresh in-service arrival", index)
	}
	// The UID is canonicalized on the way in, the same as every other feed.
	got, ok := index[busAtStopKey{"THB1703", 0, "S1"}]
	if !ok {
		t.Fatalf("index = %#v, want the canonical THB1703/0/S1 key", index)
	}
	if got.plate != "KKA-1234" {
		t.Errorf("plate = %q, want the normalized KKA-1234", got.plate)
	}
	// A2 measures no speed, and a zero would be archived as an observed
	// standstill.
	if got.speed != nil {
		t.Errorf("speed = %v, want nil", *got.speed)
	}
}

func TestBusStopEventRows(t *testing.T) {
	now := time.Date(2026, 8, 9, 8, 0, 0, 0, pipeline.Taipei)
	event := now.Add(-time.Minute)
	rows := busStopEventRows("InterCity", []rawBusNearStop{
		{
			PlateNumb: "KKA-1234", SubRouteUID: "THB170302", Direction: 9, StopUID: "S1",
			StopSequence: 4, A2EventType: 1, GPSTime: nearStopAt(now, -time.Minute),
			TripStartTime: "2026-08-09T07:30:00+08:00", TripStartTimeType: 1,
		},
		// Kept despite being stale and out of service: the archive records what
		// the feed said, and only the live attribution needs a fresh reading.
		{PlateNumb: "OLD-1", SubRouteUID: "THB170302", StopUID: "S2", GPSTime: nearStopAt(now, -3*time.Hour), DutyStatus: 2},
		{PlateNumb: "NOSTOP", SubRouteUID: "THB170302", GPSTime: nearStopAt(now, -time.Minute)},
	}, now)

	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 (the stopless record dropped)", len(rows))
	}
	want := []any{
		"KKA-1234", "InterCity", "THB1703", int16(1), "S1", int16(4),
		int16(1), event, time.Date(2026, 8, 9, 7, 30, 0, 0, pipeline.Taipei), int16(1), now,
	}
	if len(rows[0]) != len(history.BusStopEventCols) {
		t.Fatalf("row width = %d, want %d columns", len(rows[0]), len(history.BusStopEventCols))
	}
	for i, got := range rows[0] {
		if gotTime, ok := got.(time.Time); ok {
			if !gotTime.Equal(want[i].(time.Time)) {
				t.Errorf("column %s = %v, want %v", history.BusStopEventCols[i], gotTime, want[i])
			}
			continue
		}
		if got != want[i] {
			t.Errorf("column %s = %v, want %v", history.BusStopEventCols[i], got, want[i])
		}
	}
	// An unparseable or absent TripStartTime is NULL, not a zero instant.
	if rows[1][8] != nil {
		t.Errorf("trip_start_time = %v, want nil", rows[1][8])
	}
}
