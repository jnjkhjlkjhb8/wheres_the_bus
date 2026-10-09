package main

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/redis/go-redis/v9"
	"google.golang.org/protobuf/proto"
)

// loaderTestPool connects to the DATABASE_URL cluster and skips when it is unset
// or the raw_tdx schema is not provisioned, mirroring the dumpRawTDX DB tests.
func loaderTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required for DB integration tests")
		}
		t.Skip("DATABASE_URL not set; skipping loader integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	var provisioned bool
	if err := pool.QueryRow(context.Background(), `
		SELECT to_regclass('raw_tdx.bus_route') IS NOT NULL
		   AND to_regclass('raw_tdx.landing_state') IS NOT NULL
		   AND EXISTS (
			 SELECT 1 FROM information_schema.columns
			 WHERE table_schema='raw_tdx' AND table_name='landing_state'
			   AND column_name='landing_cycle')`).Scan(&provisioned); err != nil {
		pool.Close()
		t.Fatalf("probe raw_tdx schema: %v", err)
	}
	if !provisioned {
		pool.Close()
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("raw_tdx schema not provisioned")
		}
		t.Skip("raw_tdx schema or landing-cycle migration not provisioned; skipping loader integration test")
	}
	return pool
}

// TestRawTDXSourceStripsBookkeeping lands a partitioned row and asserts the
// reconstructed element carries the TDX fields but neither the partition column
// (city) nor fetched_at, and that landing_state freshness comes back fresh.
func TestRawTDXSourceStripsBookkeeping(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	const city = "ZZ_LOAD_CITY"
	cleanup := func() {
		_, _ = pool.Exec(ctx, "DELETE FROM raw_tdx.bus_route WHERE city=$1", city)
		deleteRawLandingState(ctx, pool, "bus_route", "city", city)
	}
	cleanup()
	defer cleanup()

	body := []byte(`[{"RouteUID":"ZZR1","RouteName":{"Zh_tw":"測"},"VersionID":7}]`)
	if err := raw.DumpWithDB(ctx, pool, raw.Target{Table: "bus_route", PartCol: "city", PartVal: city}, "TEST-ROUTE", "test-cycle-route", body); err != nil {
		t.Fatalf("land: %v", err)
	}

	src := rawTDXSource{pool: pool}
	arr, fetchedAt, err := src.DatasetJSON(ctx, "bus_route", "city", city)
	if err != nil {
		t.Fatalf("datasetJSON: %v", err)
	}
	if raw.IsStale(fetchedAt) {
		t.Fatalf("just-landed partition reported stale (fetched_at=%s)", fetchedAt)
	}
	var elems []map[string]json.RawMessage
	if err := json.Unmarshal(arr, &elems); err != nil {
		t.Fatalf("unmarshal reconstructed array: %v", err)
	}
	if len(elems) != 1 {
		t.Fatalf("got %d elements, want 1", len(elems))
	}
	if _, ok := elems[0]["fetched_at"]; ok {
		t.Fatal("fetched_at leaked into reconstructed element")
	}
	if _, ok := elems[0]["city"]; ok {
		t.Fatal("partition column city leaked into reconstructed element")
	}
	// Lowercased TDX keys survive (jsonb columns) and decode into the transform
	// structs (json.Unmarshal is case-insensitive).
	if _, ok := elems[0]["routeuid"]; !ok {
		t.Fatalf("routeuid missing from reconstructed element: %s", arr)
	}
}

// TestRawTDXSourceEmptyPartitionIsStale asserts an absent partition yields "[]"
// and an epoch fetched_at that isStale treats as stale (so the loader skips it).
func TestRawTDXSourceEmptyPartitionIsStale(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	src := rawTDXSource{pool: pool}
	arr, fetchedAt, err := src.DatasetJSON(ctx, "bus_route", "city", "ZZ_NO_SUCH_CITY")
	if err != nil {
		t.Fatalf("datasetJSON: %v", err)
	}
	if string(arr) != "[]" {
		t.Fatalf("empty partition array = %s, want []", arr)
	}
	if !raw.IsStale(fetchedAt) {
		t.Fatal("empty partition should be stale (epoch fetched_at)")
	}
}

func TestRawTDXSourceTHSRTraindateNormalized(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	const date = "2026-07-04"
	cleanup := func() {
		_, _ = pool.Exec(ctx, "DELETE FROM raw_tdx.thsr_dailytimetable WHERE traindate = $1", date)
		deleteRawLandingState(ctx, pool, "thsr_dailytimetable", "traindate", date)
	}
	cleanup()
	defer cleanup()

	body := []byte(`[{"TrainDate":"2026-07-04","DailyTrainInfo":{"TrainNo":"0101"},"StopTimes":[],"VersionID":1}]`)
	if err := raw.DumpWithDB(ctx, pool, raw.Target{Table: "thsr_dailytimetable", PartCol: "traindate", PartVal: date}, "TEST-THSR", "test-cycle-thsr", body); err != nil {
		t.Fatalf("land: %v", err)
	}

	src := rawTDXSource{pool: pool}
	arr, _, err := src.DatasetJSON(ctx, "thsr_dailytimetable", "traindate", date)
	if err != nil {
		t.Fatalf("datasetJSON: %v", err)
	}
	var elems []struct {
		TrainDate string `json:"traindate"`
	}
	if err := json.Unmarshal(arr, &elems); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(elems) != 1 {
		t.Fatalf("got %d elements, want 1: %s", len(elems), arr)
	}
	if elems[0].TrainDate != date {
		t.Fatalf("traindate = %q, want %q (timestamptz not normalized to date)", elems[0].TrainDate, date)
	}
	// The value must also parse into the transform's TrainDate string as a date.
	if _, err := time.Parse("2006-01-02", elems[0].TrainDate); err != nil {
		t.Fatalf("traindate not a bare date: %v", err)
	}
}

// TestRunLoadThroughRawTDXSource exercises the full seam end to end: land a TRA
// station partition, then run the tra_station loader spec through runLoad against
// the raw_tdx source and assert the transform wrote the env-schema table.
func TestRunLoadThroughRawTDXSource(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	// tra_station is unpartitioned (TRUNCATE lifecycle); skip if the env-schema
	// sink table is absent (fresh raw_tdx-only DB has no tra_stations).
	var sink bool
	if err := pool.QueryRow(ctx, "SELECT to_regclass('tra_stations') IS NOT NULL").Scan(&sink); err != nil {
		t.Fatalf("probe sink: %v", err)
	}
	if !sink {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatalf("tra_stations env table absent; required loader fixture is missing")
		}
		t.Skip("tra_stations env table absent; skipping end-to-end loader test")
	}
	if _, err := pool.Exec(ctx, `ALTER TABLE tra_stations ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT NOW()`); err != nil {
		t.Fatalf("provision tra_stations updated_at: %v", err)
	}

	const sid = "ZZ_LOAD_STATION"
	sinkCleanup := func() { _, _ = pool.Exec(ctx, "DELETE FROM tra_stations WHERE station_id=$1", sid) }
	sinkCleanup()
	defer sinkCleanup()

	body := []byte(`[{"StationID":"ZZ_LOAD_STATION","StationName":{"Zh_tw":"測站"},"LocationCityCode":"TPE","StationPosition":{"PositionLon":121.5,"PositionLat":25.0},"StationCode":"Z1"}]`)
	if err := raw.DumpWithDB(ctx, pool, raw.Target{Table: "tra_station", PartCol: "", PartVal: ""}, "TEST-TRA", "test-cycle-tra", body); err != nil {
		t.Fatalf("land: %v", err)
	}
	defer func() {
		_, _ = pool.Exec(ctx, "TRUNCATE raw_tdx.tra_station")
		deleteRawLandingState(ctx, pool, "tra_station", "", "")
	}()

	src := rawTDXSource{pool: pool}
	if _, err := runLoad(ctx, src, pool, nil, []string{"tra_station"}); err != nil {
		t.Fatalf("runLoad: %v", err)
	}
	var n int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM tra_stations WHERE station_id=$1", sid).Scan(&n); err != nil {
		t.Fatalf("count sink: %v", err)
	}
	if n != 1 {
		t.Fatalf("tra_stations rows = %d, want 1", n)
	}
}

func provisionBusSinks(t *testing.T, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	ddl := []string{
		`CREATE EXTENSION IF NOT EXISTS postgis`,
		`DO $$ BEGIN
			CREATE TYPE stop AS (station_uid text, stop_name text, stop_sequence int, position_lon float, position_lat float);
		EXCEPTION WHEN duplicate_object THEN NULL; END $$`,
		`CREATE TABLE IF NOT EXISTS bus_operators (
			operator_id text NOT NULL, authority_code text NOT NULL,
			operator_name text NOT NULL, operator_phone text, operator_url text,
			updated_at timestamptz NOT NULL DEFAULT NOW(),
			PRIMARY KEY (operator_id, authority_code))`,
		`CREATE TABLE IF NOT EXISTS bus_subroutes (
			sub_route_uid text NOT NULL, route_uid text, direction smallint NOT NULL,
			route_name text, sub_route_name text, city text, depart text, destin text,
			geometry text, stops stop[], schedule jsonb, operators jsonb,
			updated_at timestamptz NOT NULL DEFAULT NOW(),
			PRIMARY KEY (sub_route_uid, direction))`,
		`CREATE TABLE IF NOT EXISTS bus_stations (
			station_uid text PRIMARY KEY, station_name text, city text,
			position geometry(Point,4326), updated_at timestamptz NOT NULL DEFAULT NOW())`,
		`CREATE TABLE IF NOT EXISTS bus_station_groups (
			group_uid text PRIMARY KEY, group_id text, group_name text, city text,
			position geometry(Point,4326), source text,
			updated_at timestamptz NOT NULL DEFAULT NOW(), UNIQUE (city, group_id))`,
		`CREATE TABLE IF NOT EXISTS bus_station_group_members (
			station_uid text PRIMARY KEY,
			group_uid text REFERENCES bus_station_groups(group_uid),
			station_id text, station_name text, city text,
			position geometry(Point,4326), updated_at timestamptz NOT NULL DEFAULT NOW())`,
		`CREATE TABLE IF NOT EXISTS bus_static (
			sub_route_name text, route_name text, sub_route_uid text PRIMARY KEY,
			route_uid text, city text, depart text, destin text, pb bytea,
			updated_at timestamptz NOT NULL DEFAULT NOW())`,
		`CREATE TABLE IF NOT EXISTS bus_station_stop_map (
			station_id text, station_name text, sub_route_uid text, route_name text,
			direction int, stop_uid text, stop_sequence int,
			updated_at timestamptz NOT NULL DEFAULT NOW(),
			PRIMARY KEY (sub_route_uid, stop_uid, direction))`,
		// No unique Key: bus_schedule is partition-replace (DELETE by
		// sub_route_uid prefix, then plain INSERT), and circular routes produce
		// duplicate natural keys that must all survive.
		`CREATE TABLE IF NOT EXISTS bus_schedule (
			sub_route_uid text, direction smallint, type bool, tripid text,
			islowfloor bool, stopsequence smallint,
			"stop_uid/MinHeadwayMins" text, "stop_name/MaxHeadwayMins" text,
			"arrival_time/StartTime" time, "departure_time/EndTime" time,
			service_day smallint, updated_at timestamptz NOT NULL DEFAULT NOW())`,
	}
	for _, s := range ddl {
		if _, err := pool.Exec(ctx, s); err != nil {
			if strings.Contains(s, "CREATE EXTENSION") {
				t.Skipf("PostGIS unavailable; skipping complete bus integration: %v", err)
			}
			t.Fatalf("provision sink: %v\nDDL: %s", err, s)
		}
	}
}

func TestLoadBusEnrichesFromRawTDX(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	provisionBusSinks(t, ctx, pool)

	const city = "ZZLoadCity"
	const subUID = "ZZZ100"
	const opID = "ZZ_LOAD_OP"
	busmodel.CityPrefix[city] = "ZZZ"
	defer delete(busmodel.CityPrefix, city)

	cleanup := func() {
		for _, tbl := range []string{"bus_route", "bus_stopofroute", "bus_shape", "bus_schedule", "bus_station", "bus_stationgroup", "bus_operator", "bus_routefare"} {
			_, _ = pool.Exec(ctx, "DELETE FROM raw_tdx."+tbl+" WHERE city=$1", city)
			deleteRawLandingState(ctx, pool, tbl, "city", city)
		}
		_, _ = pool.Exec(ctx, "DELETE FROM bus_subroutes WHERE sub_route_uid=$1", subUID)
		_, _ = pool.Exec(ctx, "DELETE FROM bus_static WHERE sub_route_uid=$1", subUID)
		_, _ = pool.Exec(ctx, "DELETE FROM bus_station_group_members WHERE city=$1", city)
		_, _ = pool.Exec(ctx, "DELETE FROM bus_station_groups WHERE city=$1", city)
		_, _ = pool.Exec(ctx, "DELETE FROM bus_stations WHERE city=$1", city)
		_, _ = pool.Exec(ctx, "DELETE FROM bus_station_stop_map WHERE sub_route_uid LIKE 'ZZZ%'")
		_, _ = pool.Exec(ctx, "DELETE FROM bus_schedule WHERE sub_route_uid LIKE 'ZZZ%'")
		_, _ = pool.Exec(ctx, "DELETE FROM bus_operators WHERE operator_id=$1", opID)
	}
	cleanup()
	defer cleanup()

	// Fixture: one route with one operator-referencing subroute, its operator
	// registry entry, and a matching subroute fare. Empty arrays for the bus
	// datasets loadBus reads but this fixture does not exercise.
	const landingCycle = "test-cycle-bus-city"
	land := func(table, body string) {
		if err := raw.DumpWithDB(ctx, pool, raw.Target{Table: table, PartCol: "city", PartVal: city}, "TEST-BUS", landingCycle, []byte(body)); err != nil {
			t.Fatalf("land %s: %v", table, err)
		}
	}
	land("bus_route", `[{"RouteUID":"ZZZ1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"ZZ_LOAD_OP"}],"SubRoutes":[{"SubRouteUID":"ZZZ100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":0}]}]`)
	land("bus_stopofroute", `[{"RouteUID":"ZZZ1","SubRouteUID":"ZZZ100","Direction":0,"Stops":[{"StopUID":"ZZZ_S1","StopName":{"Zh_tw":"站一"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":120.8,"PositionLat":24.5}}]}]`)
	land("bus_shape", `[]`)
	land("bus_schedule", `[]`)
	land("bus_station", `[{"StationUID":"ZZZST1","StationID":"ST1","StationName":{"Zh_tw":"站一"},"StationPosition":{"PositionLon":120.8,"PositionLat":24.5}}]`)
	land("bus_stationgroup", `[]`)
	land("bus_operator", `[{"OperatorID":"ZZ_LOAD_OP","OperatorName":{"Zh_tw":"測運"},"OperatorPhone":"02-1234","OperatorUrl":"https://ex","AuthorityCode":"ZZZ"}]`)
	land("bus_routefare", `[{"RouteID":"1","SubRouteID":"100","FarePricingType":1,"IsFreeBus":0}]`)

	// Point Redis at an unreachable address: the DB snapshot must remain committed
	// and the post-commit generation failure must be returned for retry.
	rc := redis.NewClient(&redis.Options{
		Addr:         "127.0.0.1:1",
		DialTimeout:  time.Millisecond,
		ReadTimeout:  time.Millisecond,
		WriteTimeout: time.Millisecond,
		MaxRetries:   0,
	})
	defer func() { _ = rc.Close() }()

	src := rawTDXSource{pool: pool}
	if err := bus.Load(ctx, src, pool, rc, city); err == nil || !errMentions(err, "committed; invalidate cache") {
		t.Fatalf("loadBus error = %v, want committed cache-invalidation failure", err)
	}

	// (1) subroute row exists with operator detail embedded.
	var opsJSON []byte
	if err := pool.QueryRow(ctx, "SELECT operators FROM bus_subroutes WHERE sub_route_uid=$1", subUID).Scan(&opsJSON); err != nil {
		t.Fatalf("read bus_subroutes: %v", err)
	}
	if !strings.Contains(string(opsJSON), opID) {
		t.Fatalf("bus_subroutes.operators = %s, want it to contain operator %s", opsJSON, opID)
	}

	// (2) the serialized proto in bus_static carries the fare (fare is embedded in
	// the proto blob, not a bus_subroutes column).
	var pb []byte
	if err := pool.QueryRow(ctx, "SELECT pb FROM bus_static WHERE sub_route_uid=$1", subUID).Scan(&pb); err != nil {
		t.Fatalf("read bus_static.pb: %v", err)
	}
	var sub models.BusSubroute
	if err := proto.Unmarshal(pb, &sub); err != nil {
		t.Fatalf("unmarshal bus_static.pb: %v", err)
	}
	if sub.Fare == nil {
		t.Fatal("bus_static.pb subroute has nil Fare; fare enrichment did not flow")
	}
	if len(sub.Operators) == 0 {
		t.Fatal("bus_static.pb subroute has no Operators; operator enrichment did not flow")
	}

	// Operator target rows commit in the same city transaction as routes.
	var opRows int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM bus_operators WHERE operator_id=$1", opID).Scan(&opRows); err != nil {
		t.Fatalf("count bus_operators: %v", err)
	}
	if opRows != 1 {
		t.Fatalf("bus_operators rows for %s = %d, want 1 from bus snapshot", opID, opRows)
	}
}

// TestVerifyAndTouchRawLandingRefreshesState guards the 304 staleness seam: a
// TDX Not-Modified response lands nothing, so landing-state freshness must move
// forward without mass-updating the raw rows.
func TestVerifyAndTouchRawLandingRefreshesState(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	const date = "2020-01-02" // fake partition far outside any real landing window
	cleanup := func() {
		_, _ = pool.Exec(ctx, "DELETE FROM raw_tdx.thsr_dailytimetable WHERE traindate = $1", date)
		deleteRawLandingState(ctx, pool, "thsr_dailytimetable", "traindate", date)
	}
	cleanup()
	defer cleanup()

	body := []byte(`[{"TrainDate":"2020-01-02","DailyTrainInfo":{"TrainNo":"0101"},"StopTimes":[],"VersionID":1}]`)
	if err := raw.DumpWithDB(ctx, pool, raw.Target{Table: "thsr_dailytimetable", PartCol: "traindate", PartVal: date}, "TEST-304", "test-cycle-304-full", body); err != nil {
		t.Fatalf("land: %v", err)
	}
	// Backdate the landing past the 27h freshness window, as if every ingest run
	// since then answered 304.
	if _, err := pool.Exec(ctx, `UPDATE raw_tdx.landing_state
		SET fetched_at = now() - interval '48 hours'
		WHERE table_name='thsr_dailytimetable' AND partition_column='traindate' AND partition_value=$1`, date); err != nil {
		t.Fatalf("backdate: %v", err)
	}

	src := rawTDXSource{pool: pool}
	if _, fetchedAt, err := src.DatasetJSON(ctx, "thsr_dailytimetable", "traindate", date); err != nil {
		t.Fatalf("datasetJSON: %v", err)
	} else if !raw.IsStale(fetchedAt) {
		t.Fatalf("backdated partition not stale (fetched_at=%s); test premise broken", fetchedAt)
	}

	if err := raw.VerifyAndTouchLandingWithDB(ctx, pool, raw.Target{Table: "thsr_dailytimetable", PartCol: "traindate", PartVal: date}, "TEST-304", "test-cycle-304-touch"); err != nil {
		t.Fatalf("raw.VerifyAndTouchLanding: %v", err)
	}

	if _, fetchedAt, err := src.DatasetJSON(ctx, "thsr_dailytimetable", "traindate", date); err != nil {
		t.Fatalf("datasetJSON after touch: %v", err)
	} else if raw.IsStale(fetchedAt) {
		t.Fatalf("touched partition still stale (fetched_at=%s)", fetchedAt)
	}
}

func deleteRawLandingState(ctx context.Context, pool *pgxpool.Pool, table, partCol, partVal string) {
	_, _ = pool.Exec(ctx, `DELETE FROM raw_tdx.landing_state
		WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3`, table, partCol, partVal)
}
