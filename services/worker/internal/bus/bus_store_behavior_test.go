package bus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
)

func TestBusStaticStopsQueriesGroupingAliasesAndDestination(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL required")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("quality_bus_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+quoted); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(ctx, "DROP SCHEMA "+quoted+" CASCADE"); admin.Close() })
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := db.Exec(ctx, `
 CREATE TABLE bus_station_stop_map(station_id text,station_name text,sub_route_uid text,route_name text,direction int,stop_uid text,stop_sequence int);
 CREATE TABLE bus_static(sub_route_uid text,route_uid text,destin text,turnaround_stop_sequence smallint);
 CREATE TABLE bus_subroutes(sub_route_uid text,direction int,destin text);
 CREATE TABLE bus_stations(station_uid text,position geometry(Point,4326));
 CREATE TABLE bus_stop_alias(sub_route_uid text,direction int,stop_uid text,alias_stop_uid text);
 CREATE TABLE bus_station_groups(group_uid text,group_name text);
 CREATE TABLE bus_station_group_members(station_uid text,group_uid text);
 INSERT INTO bus_station_stop_map VALUES('station','Name','QBUS1','Route',1,'stop',2),('other','Other','OTHER','Other',0,'other',1);
 INSERT INTO bus_static VALUES('QBUS1','route','Fallback');
 INSERT INTO bus_subroutes VALUES('QBUS1',1,'Direction destination');
 INSERT INTO bus_stations VALUES('station',ST_SetSRID(ST_MakePoint(121.5,25),4326));
 INSERT INTO bus_stop_alias VALUES('QBUS1',1,'stop','alias');
 INSERT INTO bus_station_groups VALUES('group','Grouped station');
 INSERT INTO bus_station_group_members VALUES('station','group');`); err != nil {
		t.Fatal(err)
	}
	got, err := busstaticmp(ctx, db, "QBUS")
	if err != nil || len(got) != 1 {
		t.Fatalf("static=%v %v", got, err)
	}
	b := got[0]
	if b.StationUID != "station" || b.StationName != "Name" || b.GroupUID != "group" || b.GroupName != "Grouped station" || b.SubRouteUID != "QBUS1" || b.RouteUID != "route" || b.SubRouteName != "Route" || b.Destination != "Direction destination" || b.Direction != 1 || b.StopUID != "stop" || b.StopSequence != 2 || b.Lat != 25 || b.Lon != 121.5 || len(b.AliasStopUIDs) != 1 || b.AliasStopUIDs[0] != "alias" {
		t.Fatalf("station=%+v", b)
	}
	if _, err := db.Exec(ctx, "INSERT INTO bus_station_stop_map VALUES('overflow','Name','BAD','Route',999,'stop',2)"); err != nil {
		t.Fatal(err)
	}
	if _, err := busstaticmp(ctx, db, "BAD"); err == nil {
		t.Fatal("invalid direction row did not surface scan failure")
	}
	empty, err := busstaticmp(ctx, db, "missing")
	if err != nil || len(empty) != 0 {
		t.Fatalf("unlanded=%v %v", empty, err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := busstaticmp(canceled, db, "QBUS"); err == nil {
		t.Fatal("canceled static query succeeded")
	}
}

func TestNearStopFetchErrorsAndNotModifiedDoNotAcknowledge(t *testing.T) {
	sentinel := errors.New("feed unavailable")
	if _, err := nearStopRecords(context.Background(), func(context.Context, string, string) (*shared.TDXFetch, error) { return nil, sentinel }, "InterCity"); !errors.Is(err, sentinel) {
		t.Fatalf("fetch=%v", err)
	}
	for _, tc := range []struct {
		modified                  bool
		body                      string
		closeErr, errorInvalidate error
	}{{false, "", nil, sentinel}, {true, "[{", nil, nil}, {true, "[]", sentinel, nil}} {
		invalidated, acked := 0, 0
		fetch := func(_ context.Context, url, name string) (*shared.TDXFetch, error) {
			if url != "/v2/Bus/RealTimeNearStop/InterCity" || name != "bus_RealTimeNearStopInterCity" {
				t.Fatalf("fetch target=%s %s", url, name)
			}
			return &shared.TDXFetch{Modified: tc.modified, Decoder: json.NewDecoder(strings.NewReader(tc.body)), Close: func() error { return tc.closeErr }, Ack: func() error { acked++; return nil }, Invalidate: func() error { invalidated++; return tc.errorInvalidate }}, nil
		}
		if _, err := nearStopRecords(context.Background(), fetch, "InterCity"); err == nil {
			t.Fatal("invalid near-stop response succeeded")
		}
		if acked != 0 {
			t.Fatal("failed decode acknowledged")
		}
		if !tc.modified && invalidated != 1 {
			t.Fatal("304 did not invalidate unavailable near-stop raw cache")
		}
	}
	now := time.Now().Truncate(time.Second)
	if !freshNearStop(now.Add(-_busNearStopMaxAge).Unix(), now) || freshNearStop(now.Add(-_busNearStopMaxAge-time.Second).Unix(), now) || freshNearStop(0, now) {
		t.Fatal("near-stop freshness boundary")
	}
}
