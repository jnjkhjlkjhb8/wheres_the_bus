package raw

import "testing"

func TestRawPartitionWhere(t *testing.T) {
	// thsr_dailytimetable.traindate is timestamptz landed at Taipei midnight, so
	// it must be matched by Taipei calendar date, not a raw string equality.
	if got := PartitionWhere(Target{Table: "thsr_dailytimetable", PartCol: "traindate"}); got != "WHERE (traindate AT TIME ZONE 'Asia/Taipei')::date = $1::date" {
		t.Errorf("thsr: got %q", got)
	}
	// tra_dailytimetable.traindate is text; plain equality is correct.
	if got := PartitionWhere(Target{Table: "tra_dailytimetable", PartCol: "traindate"}); got != "WHERE traindate = $1" {
		t.Errorf("tra: got %q", got)
	}
	// Non-rail partitions (text city/system) keep plain equality.
	if got := PartitionWhere(Target{Table: "bus_route", PartCol: "city"}); got != "WHERE city = $1" {
		t.Errorf("bus: got %q", got)
	}
}
