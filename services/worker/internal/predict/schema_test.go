package predict

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

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
