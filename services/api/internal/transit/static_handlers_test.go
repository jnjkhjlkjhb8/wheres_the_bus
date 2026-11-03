package transit

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/store"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func transitTestServices(t *testing.T) (*pgxpool.Pool, *redis.Client) {
	t.Helper()
	dsn, addr := os.Getenv("DATABASE_URL"), os.Getenv("REDIS_TEST_ADDR")
	if dsn == "" || addr == "" {
		t.Skip("DATABASE_URL or REDIS_TEST_ADDR not set")
	}
	db, err := pgxpool.New(t.Context(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	return db, rc
}

func TestBikeStaticLoadsCoordinatesAndUsesCachedPayload(t *testing.T) {
	db, rc := transitTestServices(t)
	uid := fmt.Sprintf("quality-bike-static-%d", os.Getpid())
	if _, err := db.Exec(t.Context(), `INSERT INTO bike_stations(station_uid,station_id,city,name,capacity,service_type,address,geom) VALUES($1,$1,'Taipei','自行車站',15,2,'路口',ST_SetSRID(ST_MakePoint(121.5,25.25),4326))`, uid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(context.Background(), "DELETE FROM bike_stations WHERE station_uid=$1", uid) })
	responses := cache.NewTTLCache()
	server := NewBikeServer(db, rc, responses, nil)
	want := &pb.BikeStatic{StationUID: uid, Name: "自行車站", Capacity: 15, ServiceType: 2, Address: "路口", Lat: "25.250000", Lon: "121.500000"}
	for range 2 {
		got, err := server.Static(t.Context(), &pb.BikeRequest{StationUID: uid})
		if err != nil || !proto.Equal(got, want) {
			t.Fatalf("bike static = %v, error %v", got, err)
		}
	}
	responses.Set("bike_static:"+uid, []byte{0xff}, time.Hour)
	if got, err := server.Static(t.Context(), &pb.BikeRequest{StationUID: uid}); err != nil || !proto.Equal(got, want) {
		t.Fatalf("corrupt cache fallback = %v, error %v", got, err)
	}
	if _, err := server.Static(t.Context(), &pb.BikeRequest{StationUID: uid + "-missing"}); status.Code(err) != codes.NotFound {
		t.Fatalf("missing bike error = %v", err)
	}
	if _, err := NewBikeServer(db, rc, nil, nil).Static(t.Context(), &pb.BikeRequest{StationUID: uid}); err != nil {
		t.Fatalf("uncached bike error = %v", err)
	}
}

func TestBikeStaticResponseOnlyReportsCompleteCoordinates(t *testing.T) {
	lat, lon := 24.0, 120.0
	for _, row := range []store.BikeStaticRow{{}, {Lat: &lat}, {Lon: &lon}} {
		got := bikeStaticResponse("bike", row)
		if got.Lat != "" || got.Lon != "" {
			t.Fatalf("incomplete coordinates = %v", got)
		}
	}
}

func TestBusStaticCachedPayloadAndDatabaseMiss(t *testing.T) {
	db, rc := transitTestServices(t)
	uid := fmt.Sprintf("quality-bus-static-%d", os.Getpid())
	responses := cache.NewTTLCache()
	want := &pb.BusSubroute{SubRouteUID: uid}
	data, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	responses.Set("bus_static:"+uid, data, time.Minute)
	server := NewBusRouteServer(db, rc, responses, nil)
	got, err := server.Static(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid})
	if err != nil || !proto.Equal(got.Data, want) {
		t.Fatalf("cached bus = %v, error %v", got, err)
	}
	responses.Set("bus_static:"+uid, []byte{0xff}, time.Minute)
	if _, err := server.Static(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid}); status.Code(err) != codes.Internal {
		t.Fatalf("corrupt cache error = %v", err)
	}
	responses.Delete("bus_static:" + uid)
	if _, err := server.Static(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid}); status.Code(err) != codes.NotFound {
		t.Fatalf("unlanded bus error = %v", err)
	}
}

func TestBusStaticReadsLandedRouteAndCachesIt(t *testing.T) {
	db, rc := transitTestServices(t)
	uid := fmt.Sprintf("quality-bus-landed-%d", os.Getpid())
	want := &pb.BusSubroute{SubRouteUID: uid}
	data, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(t.Context(), `INSERT INTO bus_static(sub_route_uid,pb) VALUES($1,$2)`, uid, data); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(context.Background(), "DELETE FROM bus_static WHERE sub_route_uid=$1", uid) })
	responses := cache.NewTTLCache()
	for _, responseCache := range []*cache.TTLCache{nil, responses} {
		got, err := NewBusRouteServer(db, rc, responseCache, nil).Static(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid})
		if err != nil || !proto.Equal(got.Data, want) {
			t.Fatalf("landed route = %v, error %v", got, err)
		}
	}
	if got, ok := responses.Get("bus_static:" + uid); !ok || string(got) != string(data) {
		t.Fatalf("cached route = %v, present %v", got, ok)
	}
	if _, err := db.Exec(t.Context(), `UPDATE bus_static SET pb=$2 WHERE sub_route_uid=$1`, uid, []byte{0xff}); err != nil {
		t.Fatal(err)
	}
	if _, err := NewBusRouteServer(db, rc, nil, nil).Static(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid}); status.Code(err) != codes.Internal {
		t.Fatalf("invalid landed payload error = %v", err)
	}
}

func TestBusDailyUsesTypedPayloadAndRejectsCorruption(t *testing.T) {
	_, rc := transitTestServices(t)
	uid := fmt.Sprintf("quality-bus-daily-%d", os.Getpid())
	key := shared.BusDailyTimetableKey(uid)
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err() })
	server := NewBusRouteServer(nil, rc, nil, nil)
	want := &pb.Bus_DailyTimetables{}
	data, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	if err := rc.Set(t.Context(), key, data, time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	got, err := server.Daily(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid})
	if err != nil || !proto.Equal(got.Data, want) {
		t.Fatalf("daily payload = %v, error %v", got, err)
	}
	if err := rc.Set(t.Context(), key, []byte{0xff}, time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	if _, err := server.Daily(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid}); status.Code(err) != codes.Internal {
		t.Fatalf("corrupt daily error = %v", err)
	}
}
