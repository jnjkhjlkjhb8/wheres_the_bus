package gtfs

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	bindings "github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"google.golang.org/protobuf/proto"
)

func nativeGTFSIndexDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL required")
	}
	admin, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("quality_rt_index_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(context.Background(), "CREATE SCHEMA "+quoted+"; CREATE TABLE "+quoted+".static_release(run_id text,build_seq bigint);CREATE TABLE "+quoted+".gtfs_rt_bus_trip(run_id text,trip_id text,direction_id int,service_id text);CREATE TABLE "+quoted+".gtfs_rt_rail_trip(run_id text,service_date date,train_no text,trip_id text,stations text[]);CREATE TABLE "+quoted+".gtfs_rt_bus_offset(run_id text,sub_route_uid text,direction int,stop_uid text,offset_secs bigint)"); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+quoted+" CASCADE"); admin.Close() })
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	db, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	return db
}

func nativeGTFSRedis(t *testing.T) *redis.Client {
	t.Helper()
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR required")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 13})
	if err := rc.Ping(context.Background()).Err(); err != nil {
		rc.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		rc.Del(context.Background(), shared.BusDailyTimetableKey("TPEquality"), shared.BusRouteEtaKey("TPEquality"), shared.TraDelayHashKey, shared.TraDelayStationKey, shared.GTFSRealtimeKey())
		_ = rc.Close()
	})
	return rc
}

func TestGTFSNativeStaticIndexReloadAndRedisFeed(t *testing.T) {
	db := nativeGTFSIndexDB(t)
	rc := nativeGTFSRedis(t)
	ctx := context.Background()
	now := _gtfsRTWednesday
	builder := NewRTBuilder(db, rc)
	if err := builder.refreshIndex(ctx, now); err == nil {
		t.Fatal("unpublished static index accepted")
	}
	if _, err := db.Exec(ctx, `INSERT INTO static_release VALUES('r1',1);
 INSERT INTO gtfs_rt_bus_trip VALUES('r1','TPEquality:0:0900:x:y',0,'W:1111111'),('r1','bad',0,'W:1111111');
 INSERT INTO gtfs_rt_rail_trip VALUES('r1','2026-08-05','1120','rail-trip',ARRAY['1000','2000']);
 INSERT INTO gtfs_rt_bus_offset VALUES('r1','TPEquality',0,'S1',0),('r1','TPEquality',0,'S2',60)`); err != nil {
		t.Fatal(err)
	}
	if err := builder.refreshIndex(ctx, now); err != nil {
		t.Fatal(err)
	}
	key := gtfsRTRouteKey{subRouteUID: "TPEquality", direction: 0}
	index := builder.index
	if len(index.trips[key]) != 1 || !index.rail["1120"].stations["2000"] || index.offsets[key]["S2"] != 60 {
		t.Fatalf("index=%v", index)
	}
	if err := builder.refreshIndex(ctx, now); err != nil || builder.index != index {
		t.Fatal("unchanged release reloaded")
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if err := builder.refreshIndex(canceled, now); err != nil || builder.index != index {
		t.Fatal("release failure discarded existing index")
	}
	if err := (&gtfsRTBuilder{db: db}).refreshIndex(canceled, now); err == nil {
		t.Fatal("first read failure accepted")
	}
	if _, err := db.Exec(ctx, "UPDATE static_release SET run_id='r2';DROP TABLE gtfs_rt_bus_trip"); err != nil {
		t.Fatal(err)
	}
	if err := builder.refreshIndex(ctx, now); err != nil || builder.index != index {
		t.Fatal("reload failure discarded existing index")
	}
	if err := (&gtfsRTBuilder{db: db}).refreshIndex(ctx, now); err == nil {
		t.Fatal("first load failure accepted")
	}
	if err := rc.Set(ctx, shared.BusDailyTimetableKey("TPEquality"), mustGTFSPayload(t, gtfsRTDaily("TPEquality", 0, "09:00")), time.Hour).Err(); err != nil {
		t.Fatal(err)
	}
	arrival := &models.Bus_RouteArrival{SubRouteUid: "TPEquality", Stops: []*models.Bus_RouteEstimate{{StopUid: "S1", Direction: 0, PlateNumb: "A", StopSequence: 1, ArrivalUnix: now.Unix()}, {StopUid: "S2", Direction: 0, PlateNumb: "A", StopSequence: 2, ArrivalUnix: now.Add(time.Minute).Unix()}}}
	if err := rc.Set(ctx, shared.BusRouteEtaKey("TPEquality"), mustGTFSPayload(t, arrival), time.Hour).Err(); err != nil {
		t.Fatal(err)
	}
	if err := rc.HSet(ctx, shared.TraDelayHashKey, "1120", "2").Err(); err != nil {
		t.Fatal(err)
	}
	if err := rc.HSet(ctx, shared.TraDelayStationKey, "1120", "1000").Err(); err != nil {
		t.Fatal(err)
	}
	if err := builder.Run(ctx, now); err != nil {
		t.Fatal(err)
	}
	raw, err := rc.Get(ctx, shared.GTFSRealtimeKey()).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	var feed bindings.FeedMessage
	if err := proto.Unmarshal(raw, &feed); err != nil {
		t.Fatal(err)
	}
	if feed.Header.GetTimestamp() != uint64(now.Unix()) || len(feed.Entity) != 2 {
		t.Fatalf("feed=%v", &feed)
	}
	ttl := rc.TTL(ctx, shared.GTFSRealtimeKey()).Val()
	if ttl <= 0 || ttl > _gtfsRTSnapshotTTL {
		t.Fatalf("TTL=%v", ttl)
	}
}

func mustGTFSPayload(t *testing.T, message proto.Message) []byte {
	t.Helper()
	raw, err := proto.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestGTFSNativeRedisReadFailuresAndMalformedSnapshots(t *testing.T) {
	rc := nativeGTFSRedis(t)
	ctx := context.Background()
	b := NewRTBuilder(nil, rc)
	if err := rc.Set(ctx, shared.BusDailyTimetableKey("TPEquality"), "bad", time.Hour).Err(); err != nil {
		t.Fatal(err)
	}
	rows, err := b.readDailyTimetables(ctx, []string{"TPEquality", "missing"})
	if err != nil || len(rows) != 0 {
		t.Fatalf("malformed daily=%v %v", rows, err)
	}
	if err := rc.Set(ctx, shared.BusRouteEtaKey("TPEquality"), "bad", time.Hour).Err(); err != nil {
		t.Fatal(err)
	}
	arrivals, err := b.readBusArrivals(ctx)
	if err != nil || len(arrivals) != 0 {
		t.Fatalf("malformed arrivals=%v %v", arrivals, err)
	}
	if err := rc.Set(ctx, shared.BusRouteEtaKey("TPEquality"), mustGTFSPayload(t, &models.Bus_RouteArrival{}), time.Hour).Err(); err != nil {
		t.Fatal(err)
	}
	arrivals, err = b.readBusArrivals(ctx)
	if err != nil || len(arrivals) != 0 {
		t.Fatal("empty identity accepted")
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := b.readDailyTimetables(canceled, []string{"TPEquality"}); err == nil {
		t.Fatal("canceled timetable read accepted")
	}
	if _, err := b.readBusArrivals(canceled); err == nil {
		t.Fatal("canceled scan accepted")
	}
	if _, _, err := readRailDelays(canceled, rc); err == nil {
		t.Fatal("canceled rail read accepted")
	}
}
