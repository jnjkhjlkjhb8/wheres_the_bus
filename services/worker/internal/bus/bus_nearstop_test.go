package bus

import (
	"testing"
	"time"

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
