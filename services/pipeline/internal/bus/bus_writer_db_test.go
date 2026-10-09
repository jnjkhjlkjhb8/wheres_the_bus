package bus

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestWriteBusCitySnapshotDB(t *testing.T) {
	dsn := os.Getenv("BUS_WRITER_DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("BUS_WRITER_DATABASE_URL required for DB integration tests")
		}
		t.Skip("BUS_WRITER_DATABASE_URL not set; skipping atomic bus writer integration")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	schema := fmt.Sprintf("bus_writer_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, `CREATE EXTENSION IF NOT EXISTS postgis`); err != nil {
		t.Fatalf("create postgis: %v", err)
	}
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE") })

	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	db, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ddl := []string{
		`CREATE TYPE stop AS (station_uid text, stop_name text, stop_sequence int, position_lon float, position_lat float)`,
		`CREATE TABLE bus_operators (
			operator_id text, authority_code text, operator_name text,
			operator_phone text, operator_url text, updated_at timestamptz DEFAULT now(),
			PRIMARY KEY (operator_id, authority_code))`,
		`CREATE TABLE bus_subroutes (
			sub_route_uid text, route_uid text, direction int, route_name text,
			sub_route_name text, city text, depart text, destin text, geometry text,
			stops stop[], schedule jsonb, operators jsonb, updated_at timestamptz DEFAULT now(),
			PRIMARY KEY (sub_route_uid, direction))`,
		`CREATE TABLE bus_stations (
			station_uid text PRIMARY KEY, station_name text, city text,
			position geometry(Point,4326), updated_at timestamptz DEFAULT now())`,
		`CREATE TABLE bus_station_groups (
			group_uid text PRIMARY KEY, group_id text, group_name text, city text,
			position geometry(Point,4326), source text, updated_at timestamptz DEFAULT now(),
			UNIQUE (city, group_id))`,
		`CREATE TABLE bus_station_group_members (
			station_uid text PRIMARY KEY, group_uid text REFERENCES bus_station_groups(group_uid),
			station_id text, station_name text, city text, position geometry(Point,4326),
			updated_at timestamptz DEFAULT now())`,
		`CREATE TABLE bus_schedule (
			sub_route_uid text, direction smallint, type bool, tripid text,
			islowfloor bool, stopsequence smallint, "stop_uid/MinHeadwayMins" text,
			"stop_name/MaxHeadwayMins" text, "arrival_time/StartTime" time,
			"departure_time/EndTime" time, service_day smallint,
			updated_at timestamptz DEFAULT now())`,
		`CREATE TABLE bus_static (
			sub_route_name text, route_name text, sub_route_uid text PRIMARY KEY,
			route_uid text, city text, depart text, destin text, pb bytea,
			updated_at timestamptz DEFAULT now())`,
		`CREATE TABLE bus_station_stop_map (
			station_id text, station_name text, sub_route_uid text, route_name text,
			direction int, stop_uid text, stop_sequence int,
			updated_at timestamptz DEFAULT now(),
			PRIMARY KEY (sub_route_uid, stop_uid, direction))`,
	}
	for _, statement := range ddl {
		if _, err := db.Exec(ctx, statement); err != nil {
			t.Fatalf("DDL: %v\n%s", err, statement)
		}
	}
	seed := []string{
		`INSERT INTO bus_operators (operator_id, authority_code, operator_name) VALUES
			('OLD_TPE','TPE','stale'), ('KEEP_NWT','NWT','other authority')`,
		`INSERT INTO bus_stations VALUES ('TPEOLD','old','Taipei',ST_SetSRID(ST_MakePoint(121,25),4326),now()), ('TPEST1','old-city','OldCity',ST_SetSRID(ST_MakePoint(121,25),4326),now())`,
		`INSERT INTO bus_station_groups VALUES ('TPEOLDG','OLD','old','Taipei',ST_SetSRID(ST_MakePoint(121,25),4326),'tdx',now())`,
		`INSERT INTO bus_station_group_members VALUES ('TPEOLD','TPEOLDG','OLD','old','Taipei',ST_SetSRID(ST_MakePoint(121,25),4326),now())`,
		`INSERT INTO bus_schedule (sub_route_uid,direction,type) VALUES ('TPEOLD',0,false)`,
		`INSERT INTO bus_subroutes (sub_route_uid,direction,city) VALUES ('TPEOLD',0,'Taipei')`,
		`INSERT INTO bus_static (sub_route_uid,city) VALUES ('TPEOLD','Taipei')`,
		`INSERT INTO bus_station_stop_map (sub_route_uid,stop_uid,direction) VALUES ('TPEOLD','OLD',0)`,
	}
	for _, statement := range seed {
		if _, err := db.Exec(ctx, statement); err != nil {
			t.Fatalf("seed: %v\n%s", err, statement)
		}
	}

	snapshot := mustValidBusSnapshot(t)
	if err := writeBusCitySnapshot(ctx, pgBusTxBeginner{db: db}, snapshot); err != nil {
		t.Fatalf("writeBusCitySnapshot: %v", err)
	}
	checks := []struct {
		query string
		want  int
	}{
		{`SELECT count(*) FROM bus_stations WHERE city='Taipei'`, 1},
		{`SELECT count(*) FROM bus_stations WHERE station_uid='TPEOLD'`, 0},
		{`SELECT count(*) FROM bus_station_group_members WHERE station_uid='TPEOLD'`, 0},
		{`SELECT count(*) FROM bus_station_groups WHERE group_uid='TPEOLDG'`, 0},
		{`SELECT count(*) FROM bus_schedule WHERE sub_route_uid LIKE 'TPE%'`, 0},
		{`SELECT count(*) FROM bus_subroutes WHERE sub_route_uid='TPE100'`, 1},
		{`SELECT count(*) FROM bus_subroutes WHERE sub_route_uid='TPEOLD'`, 0},
		{`SELECT count(*) FROM bus_static WHERE sub_route_uid='TPE100'`, 1},
		{`SELECT count(*) FROM bus_station_stop_map WHERE sub_route_uid='TPE100'`, 1},
		{`SELECT count(*) FROM bus_station_stop_map WHERE sub_route_uid='TPEOLD'`, 0},
		{`SELECT count(*) FROM bus_operators WHERE operator_id='OP1' AND authority_code='TPE'`, 1},
		{`SELECT count(*) FROM bus_operators WHERE operator_id='OLD_TPE' AND authority_code='TPE'`, 0},
		{`SELECT count(*) FROM bus_operators WHERE operator_id='KEEP_NWT' AND authority_code='NWT'`, 1},
	}
	for _, check := range checks {
		var got int
		if err := db.QueryRow(ctx, check.query).Scan(&got); err != nil {
			t.Fatalf("check %q: %v", check.query, err)
		}
		if got != check.want {
			t.Fatalf("check %q = %d, want %d", check.query, got, check.want)
		}
	}
	var stationCity, routeUID, routeName, subrouteName, storedStationID string
	if err := db.QueryRow(ctx, `SELECT city FROM bus_stations WHERE station_uid='TPEST1'`).Scan(&stationCity); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(ctx, `SELECT route_uid,route_name,sub_route_name,(stops[1]).station_uid FROM bus_subroutes WHERE sub_route_uid='TPE100'`).Scan(&routeUID, &routeName, &subrouteName, &storedStationID); err != nil {
		t.Fatal(err)
	}
	if stationCity != "Taipei" || routeUID != "TPE1" || routeName != "1路" || subrouteName != "1路" || storedStationID != "ST1" {
		t.Fatalf("mutable fields city/route/name/subname/station = %q/%q/%q/%q/%q", stationCity, routeUID, routeName, subrouteName, storedStationID)
	}
	if strings.Contains(storedStationID, "UID") {
		t.Fatalf("stored station id = %q", storedStationID)
	}
}
