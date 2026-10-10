package predict

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// predictTestPool connects to the DATABASE_URL cluster and skips when it is
// unset, mirroring loaderTestPool.
func predictTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping BatchNextDepartures integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	return pool
}

func TestBatchNextDepartures(t *testing.T) {
	pool := predictTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	provisionBusSinks(t, ctx, pool)

	const ttUID = "ZZ_PREDICT_TT"
	const freqUID = "ZZ_PREDICT_FREQ"
	cleanup := func() {
		_, _ = pool.Exec(ctx, `DELETE FROM bus_schedule WHERE sub_route_uid IN ($1, $2)`, ttUID, freqUID)
	}
	cleanup()
	defer cleanup()
	const weekdays = 31 // Mon-Fri: bits 0-4
	const allDays = 127 // Mon-Sun: bits 0-6

	insert := `INSERT INTO bus_schedule
		(sub_route_uid, Direction, type, tripid, islowfloor, stopsequence,
		 "stop_uid/MinHeadwayMins", "stop_name/MaxHeadwayMins",
		 "arrival_time/StartTime", "departure_time/EndTime", service_day)
		VALUES ($1, $2, $3, $4, false, $5, $6, $7, $8::time, $8::time, $9)`

	// Timetable trip A: all days, stops 08:00/08:10/08:20.
	if _, err := pool.Exec(ctx, insert, ttUID, int16(0), false, "T1", int16(1), "S1", "Stop 1", "08:00:00", allDays); err != nil {
		t.Fatalf("insert trip A stop 1: %v", err)
	}
	if _, err := pool.Exec(ctx, insert, ttUID, int16(0), false, "T1", int16(2), "S2", "Stop 2", "08:10:00", allDays); err != nil {
		t.Fatalf("insert trip A stop 2: %v", err)
	}
	if _, err := pool.Exec(ctx, insert, ttUID, int16(0), false, "T1", int16(3), "S3", "Stop 3", "08:20:00", allDays); err != nil {
		t.Fatalf("insert trip A stop 3: %v", err)
	}

	// Timetable trip B: weekdays only, stops 09:00/09:10/09:20.
	if _, err := pool.Exec(ctx, insert, ttUID, int16(0), false, "T2", int16(1), "S1", "Stop 1", "09:00:00", weekdays); err != nil {
		t.Fatalf("insert trip B stop 1: %v", err)
	}
	if _, err := pool.Exec(ctx, insert, ttUID, int16(0), false, "T2", int16(2), "S2", "Stop 2", "09:10:00", weekdays); err != nil {
		t.Fatalf("insert trip B stop 2: %v", err)
	}
	if _, err := pool.Exec(ctx, insert, ttUID, int16(0), false, "T2", int16(3), "S3", "Stop 3", "09:20:00", weekdays); err != nil {
		t.Fatalf("insert trip B stop 3: %v", err)
	}

	// Frequency row: window 06:30-22:00, all days, on a different RouteDirKey.
	freqInsert := `INSERT INTO bus_schedule
		(sub_route_uid, Direction, type, tripid, islowfloor, stopsequence,
		 "stop_uid/MinHeadwayMins", "stop_name/MaxHeadwayMins",
		 "arrival_time/StartTime", "departure_time/EndTime", service_day)
		VALUES ($1, $2, true, '', false, -1, $3, $4, $5::time, $6::time, $7)`
	if _, err := pool.Exec(ctx, freqInsert, freqUID, int16(0), "10", "20", "06:30:00", "22:00:00", allDays); err != nil {
		t.Fatalf("insert frequency row: %v", err)
	}

	ttKey := RouteDirKey{SubRouteUID: ttUID, Direction: 0}
	freqKey := RouteDirKey{SubRouteUID: freqUID, Direction: 0}
	keys := []RouteDirKey{ttKey, freqKey}

	const monday = 1  // mask2 bit order: Monday = bit0
	const sunday = 64 // mask2 bit order: Sunday = bit6

	// Query at 07:00 on Monday: trip A's origin stop (08:00) wins, not 08:10.
	got := BatchNextDepartures(ctx, pool, keys, "07:00:00", monday)
	dep, ok := got[ttKey]
	if !ok {
		t.Fatal("07:00 Monday: expected a departure for the timetable route, got none")
	}
	if got, want := dep.Format("15:04:05"), "08:00:00"; got != want {
		t.Fatalf("07:00 Monday: departure = %s, want %s (origin stop, not stopsequence 0)", got, want)
	}

	// Query at 08:30 on Sunday: trip B is weekday-only, so no entry at all
	// (trip A's 08:00/08:10/08:20 are all before 08:30).
	got = BatchNextDepartures(ctx, pool, keys, "08:30:00", sunday)
	if dep, ok := got[ttKey]; ok {
		t.Fatalf("08:30 Sunday: expected no departure (weekday-only trip B excluded), got %s", dep.Format("15:04:05"))
	}

	// Query at 08:30 on Monday: trip B applies, origin stop 09:00.
	got = BatchNextDepartures(ctx, pool, keys, "08:30:00", monday)
	dep, ok = got[ttKey]
	if !ok {
		t.Fatal("08:30 Monday: expected a departure for the timetable route, got none")
	}
	if got, want := dep.Format("15:04:05"), "09:00:00"; got != want {
		t.Fatalf("08:30 Monday: departure = %s, want %s", got, want)
	}

	// Frequency route at 07:00: window already open (06:30-22:00), clamped to now.
	got = BatchNextDepartures(ctx, pool, keys, "07:00:00", monday)
	dep, ok = got[freqKey]
	if !ok {
		t.Fatal("07:00: expected a departure for the frequency route (window open), got none")
	}
	if got, want := dep.Format("15:04:05"), "07:00:00"; got != want {
		t.Fatalf("07:00: frequency departure = %s, want %s (clamped to now)", got, want)
	}

	// Two trips that share a TripID (TDX does this) both start at stop 1:
	// the earlier one is the next departure, every time.
	const dupUID = "ZZ_PREDICT_DUP"
	defer func() { _, _ = pool.Exec(ctx, `DELETE FROM bus_schedule WHERE sub_route_uid = $1`, dupUID) }()
	for _, at := range []string{"10:40:00", "10:10:00"} {
		if _, err := pool.Exec(ctx, insert, dupUID, int16(0), false, "T1", int16(1), "S1", "Stop 1", at, allDays); err != nil {
			t.Fatalf("insert shared-TripID trip at %s: %v", at, err)
		}
	}
	dupKey := RouteDirKey{SubRouteUID: dupUID, Direction: 0}
	got = BatchNextDepartures(ctx, pool, []RouteDirKey{dupKey}, "10:00:00", monday)
	if got, want := got[dupKey].Format("15:04:05"), "10:10:00"; got != want {
		t.Fatalf("shared TripID at 10:00: departure = %s, want %s", got, want)
	}

	// Frequency route at 23:00: window closed (ends 22:00), no entry.
	got = BatchNextDepartures(ctx, pool, keys, "23:00:00", monday)
	if dep, ok := got[freqKey]; ok {
		t.Fatalf("23:00: expected no departure (frequency window closed), got %s", dep.Format("15:04:05"))
	}
}

func TestBatchStopOffsets(t *testing.T) {
	pool := predictTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	provisionBusSinks(t, ctx, pool)
	if _, err := pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS bus_segment_time (
		sub_route_uid text NOT NULL, Direction smallint NOT NULL,
		from_stop_uid text NOT NULL, to_stop_uid text NOT NULL,
		secs int NOT NULL, sample_count int NOT NULL,
		updated_at timestamptz NOT NULL DEFAULT NOW(),
		PRIMARY KEY (sub_route_uid, Direction, from_stop_uid, to_stop_uid))`); err != nil {
		t.Fatalf("provision bus_segment_time: %v", err)
	}

	const whole, holed = "ZZ_OFFSET_WHOLE", "ZZ_OFFSET_HOLED"
	cleanup := func() {
		_, _ = pool.Exec(ctx, `DELETE FROM bus_station_stop_map WHERE sub_route_uid IN ($1, $2)`, whole, holed)
		_, _ = pool.Exec(ctx, `DELETE FROM bus_segment_time WHERE sub_route_uid IN ($1, $2)`, whole, holed)
		_, _ = pool.Exec(ctx, `DELETE FROM raw_tdx.bus_stopofroute WHERE subrouteuid=$1`, whole)
	}
	cleanup()
	defer cleanup()
	if _, err := pool.Exec(ctx, `INSERT INTO raw_tdx.bus_stopofroute
		(city, routeuid, subrouteuid, direction, stops)
		VALUES ('ZZ', $1, $1, 0, $2::jsonb)
		ON CONFLICT DO NOTHING`, whole, `[{"StopUID":"S1"},{"StopUID":"S2"},{"StopUID":"S3"}]`); err != nil {
		t.Fatalf("insert known stops: %v", err)
	}

	// Three stops each; the holed route is missing the S2->S3 segment.
	for _, uid := range []string{whole, holed} {
		for seq, stop := range []string{"S1", "S2", "S3"} {
			if _, err := pool.Exec(ctx, `
				INSERT INTO bus_station_stop_map (sub_route_uid, Direction, station_id, stop_uid, stop_sequence)
				VALUES ($1, 0, $2, $2, $3)`, uid, stop, seq+1); err != nil {
				t.Fatalf("insert stop map: %v", err)
			}
		}
	}
	segments := []struct {
		uid, from, to string
		secs          int
	}{
		{uid: whole, from: "S1", to: "S2", secs: 90},
		{uid: whole, from: "S2", to: "S3", secs: 150},
		{uid: holed, from: "S1", to: "S2", secs: 90},
	}
	for _, s := range segments {
		if _, err := pool.Exec(ctx, `
			INSERT INTO bus_segment_time
			  (sub_route_uid, Direction, from_stop_uid, to_stop_uid, secs, sample_count)
			VALUES ($1, 0, $2, $3, $4, 5)`, s.uid, s.from, s.to, s.secs); err != nil {
			t.Fatalf("insert segment: %v", err)
		}
	}

	offsets := BatchStopOffsets(ctx, pool, []string{whole, holed})

	for _, want := range []struct {
		stop string
		secs int
	}{{"S1", 0}, {"S2", 90}, {"S3", 240}} {
		offset, ok := offsets[StopOffsetKey{whole, 0, want.stop}]
		if !ok {
			t.Fatalf("%s %s: no offset returned", whole, want.stop)
		}
		if offset != want.secs {
			t.Errorf("%s %s offset = %d, want %d", whole, want.stop, offset, want.secs)
		}
	}
	for _, stop := range []string{"S1", "S2", "S3"} {
		if offset, ok := offsets[StopOffsetKey{holed, 0, stop}]; ok {
			t.Errorf("%s %s returned offset %d, want the incomplete Direction withheld",
				holed, stop, offset)
		}
	}
}
