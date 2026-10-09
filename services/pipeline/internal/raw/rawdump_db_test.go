package raw

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestDumpRawTDXIntegration(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required for DB integration tests")
		}
		t.Skip("DATABASE_URL not set; skipping raw_tdx integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	ctx := context.Background()
	var provisioned bool
	if err := pool.QueryRow(ctx, `
		SELECT to_regclass('raw_tdx.bus_route') IS NOT NULL
		   AND to_regclass('raw_tdx.landing_state') IS NOT NULL
		   AND EXISTS (
			 SELECT 1 FROM information_schema.columns
			 WHERE table_schema='raw_tdx' AND table_name='landing_state'
			   AND column_name='landing_cycle')`).Scan(&provisioned); err != nil {
		t.Fatalf("probe raw_tdx schema: %v", err)
	}
	if !provisioned {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("raw_tdx schema not provisioned")
		}
		t.Skip("raw_tdx schema or landing-cycle migration not provisioned; skipping raw_tdx integration test")
	}
	const city = "ZZ_TEST_CITY"
	cleanup := func() {
		_, _ = pool.Exec(ctx, "DELETE FROM raw_tdx.bus_route WHERE city=$1", city)
		_, _ = pool.Exec(ctx, `DELETE FROM raw_tdx.landing_state
			WHERE table_name='bus_route' AND partition_column='city' AND partition_value=$1`, city)
	}
	cleanup()
	defer cleanup()

	if err := DumpWithDB(ctx, pool, Target{Table: "bus_route", PartCol: "city", PartVal: city}, "TEST-EMPTY", "test-cycle-empty", []byte("[]")); err != nil {
		t.Fatalf("empty-array dump: %v", err)
	}
	if n := countCity(t, pool, city); n != 0 {
		t.Fatalf("empty array: got %d rows, want 0", n)
	}
	assertLandingState(t, pool, "bus_route", "city", city, "TEST-EMPTY", "test-cycle-empty", 0)

	body := []byte(`[{"RouteUID":"ZZR1","RouteName":{"Zh_tw":"測"},"VersionID":1}]`)
	if err := DumpWithDB(ctx, pool, Target{Table: "bus_route", PartCol: "city", PartVal: city}, "TEST-ONE", "test-cycle-one", body); err != nil {
		t.Fatalf("single-row dump: %v", err)
	}
	if n := countCity(t, pool, city); n != 1 {
		t.Fatalf("single row: got %d rows, want 1", n)
	}
	assertLandingState(t, pool, "bus_route", "city", city, "TEST-ONE", "test-cycle-one", 1)

	body2 := []byte(`[{"RouteUID":"ZZR2","VersionID":2},{"RouteUID":"ZZR3","VersionID":3}]`)
	if err := DumpWithDB(ctx, pool, Target{Table: "bus_route", PartCol: "city", PartVal: city}, "TEST-TWO", "test-cycle-two", body2); err != nil {
		t.Fatalf("partition-replace dump: %v", err)
	}
	if n := countCity(t, pool, city); n != 2 {
		t.Fatalf("partition replace: got %d rows, want 2", n)
	}
	assertLandingState(t, pool, "bus_route", "city", city, "TEST-TWO", "test-cycle-two", 2)

	if err := DumpWithDB(ctx, pool, Target{Table: "pg_class", PartCol: "city", PartVal: city}, "TEST-BAD", "test-cycle-bad", body); err == nil {
		t.Fatal("expected error for non-whitelisted table, got nil")
	}
}

func TestDumpRawTDXTHSRTraindateRoundtrip(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required for DB integration tests")
		}
		t.Skip("DATABASE_URL not set; skipping raw_tdx integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	ctx := context.Background()
	var provisioned bool
	if err := pool.QueryRow(ctx, `
		SELECT to_regclass('raw_tdx.thsr_dailytimetable') IS NOT NULL
		   AND to_regclass('raw_tdx.landing_state') IS NOT NULL
		   AND EXISTS (
			 SELECT 1 FROM information_schema.columns
			 WHERE table_schema='raw_tdx' AND table_name='landing_state'
			   AND column_name='landing_cycle')`).Scan(&provisioned); err != nil {
		t.Fatalf("probe raw_tdx schema: %v", err)
	}
	if !provisioned {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("raw_tdx schema not provisioned")
		}
		t.Skip("raw_tdx schema or landing-cycle migration not provisioned; skipping raw_tdx integration test")
	}

	const date = "2026-07-04"
	countDate := func() int {
		var n int
		if err := pool.QueryRow(ctx,
			"SELECT count(*) FROM raw_tdx.thsr_dailytimetable WHERE traindate = $1", date).Scan(&n); err != nil {
			t.Fatalf("count: %v", err)
		}
		return n
	}
	cleanup := func() {
		_, _ = pool.Exec(ctx, "DELETE FROM raw_tdx.thsr_dailytimetable WHERE traindate = $1", date)
		_, _ = pool.Exec(ctx, `DELETE FROM raw_tdx.landing_state
			WHERE table_name='thsr_dailytimetable' AND partition_column='traindate' AND partition_value=$1`, date)
	}
	cleanup()
	defer cleanup()

	// The landing partition value is the date string from the URL path; the
	// payload's own TrainDate is dropped by jsonb_populate_recordset in favor of
	// the injected traindate column (rawInsertSQL injects {"traindate": date}).
	body := []byte(`[{"TrainDate":"2026-07-04","DailyTrainInfo":{"TrainNo":"0101"},"VersionID":1}]`)
	if err := DumpWithDB(ctx, pool, Target{Table: "thsr_dailytimetable", PartCol: "traindate", PartVal: date}, "TEST-FIRST", "test-cycle-first", body); err != nil {
		t.Fatalf("first landing: %v", err)
	}
	if n := countDate(); n != 1 {
		t.Fatalf("first landing: got %d rows, want 1", n)
	}

	// Second landing for the same date must replace, not duplicate. This only
	// holds if DELETE FROM ... WHERE traindate = '2026-07-04' matches the row the
	// prior INSERT coerced to timestamptz.
	body2 := []byte(`[{"TrainDate":"2026-07-04","DailyTrainInfo":{"TrainNo":"0201"},"VersionID":2},{"TrainDate":"2026-07-04","DailyTrainInfo":{"TrainNo":"0203"},"VersionID":3}]`)
	if err := DumpWithDB(ctx, pool, Target{Table: "thsr_dailytimetable", PartCol: "traindate", PartVal: date}, "TEST-SECOND", "test-cycle-second", body2); err != nil {
		t.Fatalf("second landing: %v", err)
	}
	if n := countDate(); n != 2 {
		t.Fatalf("traindate replace: got %d rows, want 2 (DELETE param did not round-trip to timestamptz)", n)
	}
}

func countCity(t *testing.T, pool *pgxpool.Pool, city string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		"SELECT count(*) FROM raw_tdx.bus_route WHERE city=$1", city).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	return n
}

func assertLandingState(
	t *testing.T,
	pool *pgxpool.Pool,
	table, partCol, partVal, marker, landingCycle string,
	rowCount int64,
) {
	t.Helper()
	var gotMarker string
	var gotRows int64
	var gotCycle string
	if err := pool.QueryRow(context.Background(), `
		SELECT last_modified, row_count, landing_cycle FROM raw_tdx.landing_state
		WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3`,
		table, partCol, partVal).Scan(&gotMarker, &gotRows, &gotCycle); err != nil {
		t.Fatalf("read landing state: %v", err)
	}
	if gotMarker != marker || gotRows != rowCount || gotCycle != landingCycle {
		t.Fatalf("landing state marker/rows/cycle = %q/%d/%q, want %q/%d/%q", gotMarker, gotRows, gotCycle, marker, rowCount, landingCycle)
	}
}
