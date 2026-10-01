package gtfs

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestBusScheduleServiceID(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping raw_tdx integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	ctx := context.Background()

	var provisioned bool
	if err := pool.QueryRow(ctx, `
		SELECT to_regclass('raw_tdx.bus_schedule') IS NOT NULL`).Scan(&provisioned); err != nil {
		t.Fatalf("probe raw_tdx schema: %v", err)
	}
	if !provisioned {
		t.Skip("raw_tdx schema not provisioned; skipping raw_tdx integration test")
	}

	const city = "ZZ_GTFS_SVC_TEST"
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	t.Cleanup(conn.Release)
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	t.Cleanup(func() { _ = tx.Rollback(ctx) })

	// Two distinct stops with parseable times on both, so the entry survives
	// busScheduleSource's own filters; the times themselves are not under test.
	const calls = `[
		{"StopUID":"ZZ1","StopSequence":1,"ArrivalTime":"%[1]s","DepartureTime":"%[1]s"},
		{"StopUID":"ZZ2","StopSequence":2,"ArrivalTime":"%[2]s","DepartureTime":"%[2]s"}
	]`
	origin := func(dep string) string {
		return `[{"StopUID":"ZZ1","StopSequence":1,"DepartureTime":"` + dep + `"}]`
	}

	weekday := day(true /* mon */, true /* tue */, true /* wed */, true /* thu */, true, /* fri */
		false /* sat */, false /* sun */)
	weekend := day(false /* mon */, false /* tue */, false /* wed */, false /* thu */, false, /* fri */
		true /* sat */, true /* sun */)
	if _, err := tx.Exec(ctx, `
		INSERT INTO raw_tdx.bus_schedule
		  (city, routeuid, subrouteuid, direction, subroutename, timetables)
		VALUES ($1, 'ZZR', 'ZZR1', 0, '{"Zh_tw":"test"}'::jsonb, $2::jsonb)`,
		city, `[
			{"StopTimes":`+fmtCalls(calls, "06:10", "06:20")+`, "ServiceDay":`+weekday+`},
			{"StopTimes":`+fmtCalls(calls, "07:00", "07:10")+`, "ServiceDay":`+weekday+`},
			{"StopTimes":`+fmtCalls(calls, "07:00", "07:10")+`, "ServiceDay":`+weekend+`},
			{"StopTimes":`+origin("06:10")+`, "ServiceDay":`+weekday+`},
			{"StopTimes":`+origin("08:00")+`, "ServiceDay":`+weekday+`}
		]`); err != nil {
		t.Fatalf("seed schedule: %v", err)
	}

	read := func(label, source string) map[string]string {
		t.Helper()
		rows, err := tx.Query(ctx, `
			SELECT trip_id, service_id FROM (`+source+`) s
			WHERE s.routeuid = 'ZZR' ORDER BY trip_id`)
		if err != nil {
			t.Fatalf("run %s: %v", label, err)
		}
		defer rows.Close()
		got := map[string]string{}
		for rows.Next() {
			var tripID, serviceID string
			if err := rows.Scan(&tripID, &serviceID); err != nil {
				t.Fatalf("scan %s: %v", label, err)
			}
			got[tripID] = serviceID
		}
		if err := rows.Err(); err != nil {
			t.Fatalf("rows %s: %v", label, err)
		}
		return got
	}

	compare := func(label string, got, want map[string]string) {
		t.Helper()
		for tripID, wantSvc := range want {
			if got[tripID] != wantSvc {
				t.Errorf("%s: trip %s service_id = %q, want %q", label, tripID, got[tripID], wantSvc)
			}
		}
		if len(got) != len(want) {
			t.Errorf("%s: emitted %d trips, want %d: %v", label, len(got), len(want), got)
		}
		for tripID, svc := range got {
			if !strings.HasPrefix(svc, "W:") {
				t.Errorf("%s: trip %s runs on %q, want a weekly mask", label, tripID, svc)
			}
		}
	}

	compare("busScheduleSource", read("busScheduleSource", _busScheduleSource), map[string]string{
		"ZZR1:0:0610:W:1111100": "W:1111100",
		// Two patterns, two trips — the trip_id differs by the service, so they
		// do not collapse into one another.
		"ZZR1:0:0700:W:1111100": "W:1111100",
		"ZZR1:0:0700:W:0000011": "W:0000011",
	})

	// 06:10 is absent: busScheduleSource already emitted that trip_id from the
	// entry that states its calls.
	compare("busOriginTripSource", read("busOriginTripSource", _busOriginTripSource), map[string]string{
		"ZZR1:0:0800:W:1111100": "W:1111100",
	})
}

func TestBusStopBoarding(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping raw_tdx integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	ctx := context.Background()

	var provisioned bool
	if err := pool.QueryRow(ctx, `
		SELECT to_regclass('raw_tdx.bus_stopofroute') IS NOT NULL`).Scan(&provisioned); err != nil {
		t.Fatalf("probe raw_tdx schema: %v", err)
	}
	if !provisioned {
		t.Skip("raw_tdx schema not provisioned; skipping raw_tdx integration test")
	}

	// Rolled back rather than deleted, for the reason TestBusScheduleServiceID
	// states: DATABASE_URL is the shared raw_tdx the nightly export reads.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	t.Cleanup(conn.Release)
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	t.Cleanup(func() { _ = tx.Rollback(ctx) })

	if _, err := tx.Exec(ctx, `
		INSERT INTO raw_tdx.bus_stopofroute (city, routeuid, subrouteuid, direction, stops)
		VALUES ($1, 'ZZR', 'ZZB1', 0, $2::jsonb)`,
		"ZZ_GTFS_BOARD_TEST", `[
			{"StopUID":"ZZB_BOARD","StopBoarding":1},
			{"StopUID":"ZZB_ALIGHT","StopBoarding":2},
			{"StopUID":"ZZB_BOTH","StopBoarding":0},
			{"StopUID":"ZZB_UNKNOWN","StopBoarding":-1},
			{"StopUID":"ZZB_ABSENT"}
		]`); err != nil {
		t.Fatalf("seed stopofroute: %v", err)
	}

	rows, err := tx.Query(ctx, `
		SELECT stop_uid, pickup, drop_off FROM (`+_busStopBoardingSQL+`) b
		WHERE b.sub_route_uid = 'ZZB1' ORDER BY stop_uid`)
	if err != nil {
		t.Fatalf("run _busStopBoardingSQL: %v", err)
	}
	defer rows.Close()
	got := make(map[string][2]int)
	for rows.Next() {
		var stopUID string
		var pickup, dropOff int
		if err := rows.Scan(&stopUID, &pickup, &dropOff); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got[stopUID] = [2]int{pickup, dropOff}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows: %v", err)
	}

	// The unrestricted three are absent by design: they fall through the LEFT
	// JOINs in stop_times as 0, 0.
	want := map[string][2]int{
		"ZZB_BOARD":  {0, 1},
		"ZZB_ALIGHT": {1, 0},
	}
	for stopUID, wantFlags := range want {
		if got[stopUID] != wantFlags {
			t.Errorf("%s: (pickup, drop_off) = %v, want %v", stopUID, got[stopUID], wantFlags)
		}
	}
	if len(got) != len(want) {
		t.Errorf("emitted %d restricted stops, want %d: %v", len(got), len(want), got)
	}
}

func fmtCalls(tmpl, arrive, depart string) string {
	return fmt.Sprintf(tmpl, arrive, depart)
}

func day(mon, tue, wed, thu, fri, sat, sun bool) string {
	return fmt.Sprintf(`{"Monday":%t,"Tuesday":%t,"Wednesday":%t,"Thursday":%t,"Friday":%t,"Saturday":%t,"Sunday":%t}`,
		mon, tue, wed, thu, fri, sat, sun)
}
