package main

import (
	"context"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/mrt"
)

func TestLoadMrtFirstlastCollapsesDuplicateNaturalKeys(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	var haveTable bool
	if err := pool.QueryRow(ctx, "SELECT to_regclass('mrt_schedule') IS NOT NULL").Scan(&haveTable); err != nil {
		t.Fatalf("probe mrt_schedule: %v", err)
	}
	if !haveTable {
		t.Skip("mrt_schedule env table absent; skipping firstlast loader test")
	}
	// The test only reproduces the bug when the UNIQUE constraint is present:
	// without it a plain INSERT would keep both duplicates and the fix would be
	// indistinguishable. Require it so a green run is meaningful.
	var haveConstraint bool
	if err := pool.QueryRow(ctx,
		"SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'mrt_schedule_natural_key')").Scan(&haveConstraint); err != nil {
		t.Fatalf("probe constraint: %v", err)
	}
	if !haveConstraint {
		t.Skip("mrt_schedule_natural_key constraint absent; skipping firstlast loader test")
	}

	const system = "ZZ_MRT_DUP"
	cleanup := func() { _, _ = pool.Exec(ctx, "DELETE FROM mrt_schedule WHERE system=$1", system) }
	cleanup()
	defer cleanup()

	// Two rows share the natural key (same station/line/destination/serviceday)
	// but differ in FirstTrainTime — exactly the TRTC shape. A third row is a
	// distinct destination, so the collapsed result must be two rows.
	body := `[
		{"StationID":"BL12","LineID":"BL","TripHeadSign":"A","DestinationStaionID":"BL01","DestinationStationName":{"Zh_tw":"頂埔"},"FirstTrainTime":"06:00","LastTrainTime":"23:50","ServiceDay":{"Monday":true,"Tuesday":true,"Wednesday":true,"Thursday":true,"Friday":true,"Saturday":true,"Sunday":true,"NationalHolidays":true}},
		{"StationID":"BL12","LineID":"BL","TripHeadSign":"A","DestinationStaionID":"BL01","DestinationStationName":{"Zh_tw":"頂埔"},"FirstTrainTime":"06:05","LastTrainTime":"23:55","ServiceDay":{"Monday":true,"Tuesday":true,"Wednesday":true,"Thursday":true,"Friday":true,"Saturday":true,"Sunday":true,"NationalHolidays":true}},
		{"StationID":"BL12","LineID":"BL","TripHeadSign":"B","DestinationStaionID":"BL23","DestinationStationName":{"Zh_tw":"南港展覽館"},"FirstTrainTime":"06:00","LastTrainTime":"23:50","ServiceDay":{"Monday":true,"Tuesday":true,"Wednesday":true,"Thursday":true,"Friday":true,"Saturday":true,"Sunday":true,"NationalHolidays":true}}
	]`

	sink := pgLoadSink{db: pool}
	if err := mrt.LoadFirstlast(ctx, decodeInto(body), sink, system); err != nil {
		t.Fatalf("LoadFirstlast tripped the unique constraint (this is the bug): %v", err)
	}

	var n int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM mrt_schedule WHERE system=$1", system).Scan(&n); err != nil {
		t.Fatalf("count mrt_schedule: %v", err)
	}
	if n != 2 {
		t.Fatalf("mrt_schedule rows = %d, want 2 (duplicate natural key collapsed, distinct destination kept)", n)
	}
}
