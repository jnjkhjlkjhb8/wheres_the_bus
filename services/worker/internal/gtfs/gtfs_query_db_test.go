package gtfs

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func gtfsTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping GTFS statement integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	var provisioned bool
	if err := pool.QueryRow(context.Background(),
		`SELECT to_regclass('raw_tdx.bus_route') IS NOT NULL`).Scan(&provisioned); err != nil {
		t.Fatalf("probe raw_tdx schema: %v", err)
	}
	if !provisioned {
		t.Skip("raw_tdx schema not provisioned; skipping GTFS statement integration test")
	}
	return pool
}

// gtfsTestTx starts the transaction the export runs in and materializes its temp
// tables, so a test can run the feed's statements the way writeGTFSArchive does.
// It rolls back on cleanup; the temp tables go with it.
func gtfsTestTx(t *testing.T, pool *pgxpool.Pool, withData bool) pgx.Tx {
	t.Helper()
	ctx := context.Background()
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
	if err := createGTFSTempTables(ctx, tx, withData); err != nil {
		t.Fatalf("temp tables: %v", err)
	}
	return tx
}

func TestGTFSStatementsPlan(t *testing.T) {
	// The files read the export's temp tables by name, so they only resolve
	// inside a transaction that has declared them. Declared empty here: a plan
	// needs the columns, not the rows.
	tx := gtfsTestTx(t, gtfsTestPool(t), false /* withData */)
	for _, file := range gtfsFiles("20260801-0345") {
		t.Run(file.name, func(t *testing.T) {
			if _, err := tx.Exec(context.Background(), "EXPLAIN "+file.sql); err != nil {
				t.Errorf("%s does not plan: %v", file.name, err)
			}
		})
	}
}

func TestGTFSCalendarWindow(t *testing.T) {
	pool := gtfsTestPool(t)
	ctx := context.Background()

	var (
		railDays, calendarDays, disagreeing int
		first, last                         string
	)
	// min and max are COALESCEd rather than scanned into pointers: an empty
	// calendar makes them null, and the only thing this reads them for is the
	// failure message.
	err := pool.QueryRow(ctx, `
		WITH rail AS (SELECT DISTINCT service_date FROM (`+_railTripSource+`) r),
		     cal AS (SELECT DISTINCT to_date(date, 'YYYYMMDD') AS service_date
		             FROM (`+_gtfsCalendarDatesSQL+`) c)
		SELECT (SELECT count(*) FROM rail),
		       (SELECT count(*) FROM cal),
		       (SELECT count(*) FROM (
		          (SELECT * FROM rail EXCEPT SELECT * FROM cal)
		          UNION ALL
		          (SELECT * FROM cal EXCEPT SELECT * FROM rail)) d),
		       (SELECT COALESCE(to_char(min(service_date), 'YYYY-MM-DD'), '') FROM cal),
		       (SELECT COALESCE(to_char(max(service_date), 'YYYY-MM-DD'), '') FROM cal)`).
		Scan(&railDays, &calendarDays, &disagreeing, &first, &last)
	if err != nil {
		t.Fatalf("read calendar window: %v", err)
	}
	// A database with no landed rail timetable states no dates, and there is
	// nothing to check about a window that is empty for want of data.
	if railDays == 0 {
		t.Skip("no rail timetable landed; skipping calendar window check")
	}
	if calendarDays > _gtfsCalendarDays {
		t.Errorf("calendar_dates covers %d days (%s..%s), want at most %d",
			calendarDays, first, last, _gtfsCalendarDays)
	}
	if disagreeing != 0 {
		t.Errorf("%d dates are stated by rail trips or by calendar_dates but not both; "+
			"the window has been bounded in only one of them", disagreeing)
	}

	var past, future int
	if err := pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE service_date < (now() AT TIME ZONE 'Asia/Taipei')::date),
		       count(*) FILTER (WHERE service_date >= (now() AT TIME ZONE 'Asia/Taipei')::date + $1::int)
		FROM (SELECT DISTINCT service_date FROM (`+_railTripSource+`) r) d`,
		_gtfsCalendarDays).Scan(&past, &future); err != nil {
		t.Fatalf("read window bounds: %v", err)
	}
	if past != 0 || future != 0 {
		t.Errorf("rail states %d dates before today and %d at or beyond day %d",
			past, future, _gtfsCalendarDays)
	}
}

func TestGTFSSectionFareUnits(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	// A route with two buffer zones: 0 core, 1 buffer, 2 core, 3 buffer, 4 core.
	for _, c := range []struct{ from, to, want int }{
		{0, 0, 1}, // within the first section
		{0, 1, 1}, // into the buffer, no section crossed
		{0, 2, 2}, // clear through the buffer
		{0, 3, 2}, // through the first, into the second
		{0, 4, 3}, // through both
		{1, 1, 1}, // begins and ends inside one buffer
		{1, 2, 1},
		{1, 3, 1}, // buffer to buffer, neither crossed whole
		{1, 4, 2},
		{2, 4, 2},
		{3, 3, 1},
		{3, 4, 1},
		{4, 4, 1},
	} {
		var got int
		if err := pool.QueryRow(context.Background(),
			`SELECT `+busSectionUnitsSQL("$1::int", "$2::int"), c.from, c.to).Scan(&got); err != nil {
			t.Fatalf("zone %d->%d: %v", c.from, c.to, err)
		}
		if got != c.want {
			t.Errorf("zone %d->%d: %d section fares, want %d", c.from, c.to, got, c.want)
		}
	}
}

func TestGTFSFaresAreConsistent(t *testing.T) {
	if os.Getenv("GTFS_DB_HEAVY_TESTS") != "1" {
		t.Skip("GTFS_DB_HEAVY_TESTS != 1; skipping (this one scans stop_times)")
	}
	tx := gtfsTestTx(t, gtfsTestPool(t), true /* withData */)
	ctx := context.Background()

	for _, c := range []struct{ name, query string }{
		// An empty area is a wildcard, not a reference: a flat-fare network
		// prices every leg on it regardless of where the rider boards.
		{"leg rules naming an area areas.txt omits", `
			SELECT count(*) FROM (` + _gtfsFareLegRulesSQL + `) r
			WHERE (r.from_area_id <> '' AND r.from_area_id NOT IN (SELECT area_id FROM (` + _gtfsAreasSQL + `) a1))
			   OR (r.to_area_id   <> '' AND r.to_area_id   NOT IN (SELECT area_id FROM (` + _gtfsAreasSQL + `) a2))`},
		{"leg rules naming a product fare_products.txt omits", `
			SELECT count(*) FROM (` + _gtfsFareLegRulesSQL + `) r
			WHERE r.fare_product_id NOT IN (SELECT fare_product_id FROM (` + _gtfsFareProductsSQL + `) p)`},
		{"stop_areas naming a stop stops.txt omits", `
			SELECT count(*) FROM (` + _gtfsStopAreasSQL + `) sa
			WHERE sa.stop_id NOT IN (SELECT stop_id FROM (` + _gtfsStopsSQL + `) s)`},
		{"areas with no stop in them", `
			SELECT count(*) FROM (` + _gtfsAreasSQL + `) a
			WHERE a.area_id NOT IN (SELECT area_id FROM (` + _gtfsStopAreasSQL + `) sa)`},
		{"leg rules on a network no route belongs to", `
			SELECT count(*) FROM (` + _gtfsFareLegRulesSQL + `) r
			WHERE r.network_id NOT IN (SELECT network_id FROM (` + _gtfsRoutesSQL + `) ro)`},
	} {
		t.Run(c.name, func(t *testing.T) {
			var bad int
			if err := tx.QueryRow(ctx, c.query).Scan(&bad); err != nil {
				t.Fatalf("query: %v", err)
			}
			if bad != 0 {
				t.Errorf("%d %s", bad, c.name)
			}
		})
	}

	var products, rules int
	if err := tx.QueryRow(ctx,
		`SELECT (SELECT count(*) FROM (`+_gtfsFareProductsSQL+`) p),
		        (SELECT count(*) FROM (`+_gtfsFareLegRulesSQL+`) r)`).Scan(&products, &rules); err != nil {
		t.Fatalf("count: %v", err)
	}
	t.Logf("fare products=%d leg rules=%d", products, rules)
	if rules == 0 {
		// Empty fare files are only a fault when there were fares to read. A
		// database with none landed correctly prices nothing.
		var landed int
		if err := tx.QueryRow(ctx, `
			SELECT (SELECT count(*) FROM raw_tdx.bus_routefare)
			     + (SELECT count(*) FROM raw_tdx.tra_odfare)
			     + (SELECT count(*) FROM raw_tdx.thsr_odfare)
			     + (SELECT count(*) FROM raw_tdx.metro_odfare)`).Scan(&landed); err != nil {
			t.Fatalf("count landed fares: %v", err)
		}
		if landed == 0 {
			t.Skip("no fares landed; nothing to price")
		}
		t.Fatalf("%d fare records landed and not one leg rule came out", landed)
	}
	if rules >= 200 && products > rules/10 {
		t.Errorf("fare_products has %d rows for %d leg rules: products are being emitted per pair, not per price",
			products, rules)
	}
}

func TestGTFSPathwaysAreConsistent(t *testing.T) {
	if os.Getenv("GTFS_DB_HEAVY_TESTS") != "1" {
		t.Skip("GTFS_DB_HEAVY_TESTS != 1; skipping (this one scans stop_times)")
	}
	tx := gtfsTestTx(t, gtfsTestPool(t), true /* withData */)
	ctx := context.Background()

	for _, c := range []struct{ name, query string }{
		{"pathways naming a stop stops.txt omits", `
			SELECT count(*) FROM (` + _gtfsPathwaysSQL + `) p
			WHERE p.from_stop_id NOT IN (SELECT stop_id FROM (` + _gtfsStopsSQL + `) s1)
			   OR p.to_stop_id   NOT IN (SELECT stop_id FROM (` + _gtfsStopsSQL + `) s2)`},
		{"pathways ending on a station rather than an entrance or platform", `
			SELECT count(*) FROM (` + _gtfsPathwaysSQL + `) p
			JOIN (` + _gtfsStopsSQL + `) a ON a.stop_id = p.from_stop_id
			JOIN (` + _gtfsStopsSQL + `) b ON b.stop_id = p.to_stop_id
			WHERE a.location_type <> 2 OR b.location_type <> 0`},
		{"pathways whose ends belong to different stations", `
			SELECT count(*) FROM (` + _gtfsPathwaysSQL + `) p
			JOIN (` + _gtfsStopsSQL + `) a ON a.stop_id = p.from_stop_id
			JOIN (` + _gtfsStopsSQL + `) b ON b.stop_id = p.to_stop_id
			WHERE a.parent_station <> b.parent_station`},
		{"duplicate pathway_id", `
			SELECT COALESCE(sum(n) - count(*), 0) FROM (
			  SELECT count(*) AS n FROM (` + _gtfsPathwaysSQL + `) p GROUP BY p.pathway_id
			) d`},
	} {
		t.Run(c.name, func(t *testing.T) {
			var bad int
			if err := tx.QueryRow(ctx, c.query).Scan(&bad); err != nil {
				t.Fatalf("query: %v", err)
			}
			if bad != 0 {
				t.Errorf("%d %s", bad, c.name)
			}
		})
	}

	// Every entrance should be reachable. One with no pathway is an entrance a
	// router can route to and not out of.
	var stranded int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM (`+_gtfsStopsSQL+`) s
		WHERE s.location_type = 2
		  AND s.stop_id NOT IN (SELECT from_stop_id FROM (`+_gtfsPathwaysSQL+`) p)`).Scan(&stranded); err != nil {
		t.Fatalf("stranded: %v", err)
	}
	if stranded != 0 {
		t.Errorf("%d entrances have no pathway to their platform", stranded)
	}
}

func TestGTFSTranslationsReferenceEmittedRecords(t *testing.T) {
	if os.Getenv("GTFS_DB_HEAVY_TESTS") != "1" {
		t.Skip("GTFS_DB_HEAVY_TESTS != 1; skipping (this one scans stop_times)")
	}
	// gtfsStopsSQL now reads the materialized calls, so it only resolves inside
	// the export's transaction.
	tx := gtfsTestTx(t, gtfsTestPool(t), true /* withData */)
	ctx := context.Background()

	for _, c := range []struct{ table, emitted, idColumn string }{
		{"agency", _gtfsAgencySQL, "agency_id"},
		{"stops", _gtfsStopsSQL, "stop_id"},
		{"routes", _gtfsRoutesSQL, "route_id"},
	} {
		t.Run(c.table, func(t *testing.T) {
			var translated, dangling, emitted int
			var sample *string
			err := tx.QueryRow(ctx, `
				SELECT count(*),
				       count(*) FILTER (WHERE tr.record_id NOT IN (SELECT `+c.idColumn+` FROM (`+c.emitted+`) e)),
				       min(tr.record_id) FILTER (WHERE tr.record_id NOT IN (SELECT `+c.idColumn+` FROM (`+c.emitted+`) e2)),
				       (SELECT count(*) FROM (`+c.emitted+`) e3)
				FROM (`+_gtfsTranslationsSQL+`) tr
				WHERE tr.table_name = $1`, c.table).Scan(&translated, &dangling, &sample, &emitted)
			if err != nil {
				t.Fatalf("compare: %v", err)
			}
			// Nothing translated is only a fault when there was something to
			// translate. A database with no landed stops emits no stops.txt and
			// correctly translates none of it.
			if emitted > 0 && translated == 0 {
				t.Errorf("%s: %s.txt has %d rows and none of them are translated",
					c.table, c.table, emitted)
			}
			if dangling != 0 {
				got := "<null>"
				if sample != nil {
					got = *sample
				}
				t.Errorf("%s: %d of %d translation rows name a record %s.txt does not contain, e.g. %q",
					c.table, dangling, translated, c.table, got)
			}
		})
	}
}
