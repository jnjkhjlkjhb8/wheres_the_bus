package feed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func gbfsTestRedis(t *testing.T) *redis.Client {
	t.Helper()
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	return rc
}

func TestGBFSStatusChunksKeepObservationAndOmitUnknownStations(t *testing.T) {
	rc := gbfsTestRedis(t)
	stations := make([]gbfsStation, _gbfsStatusChunk+1)
	keys := make([]string, 0, 2*len(stations))
	for i := range stations {
		stations[i].StationID = fmt.Sprintf("quality-gbfs-%d-%d", os.Getpid(), i)
		keys = append(keys, shared.BikeAvailabilityKey(stations[i].StationID), shared.BikeAvailabilityObservedAtKey(stations[i].StationID))
	}
	t.Cleanup(func() { _ = rc.Del(context.Background(), keys...).Err() })
	for _, i := range []int{0, _gbfsStatusChunk} {
		payload := mustMarshalBikeEta(t, &models.BikeEta{StationUID: stations[i].StationID, GeneralBikes: 3, ElectricBikes: 2, AvailableReturnBikes: 7, ServiceStatus: 1})
		if err := rc.MSet(t.Context(), keys[2*i], payload, keys[2*i+1], "1700000000").Err(); err != nil {
			t.Fatal(err)
		}
	}
	if err := rc.Set(t.Context(), keys[2], []byte{0xff}, time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	got, err := buildGBFSStatuses(t.Context(), rc, stations)
	if err != nil || len(got) != 2 {
		t.Fatalf("statuses = %v, error %v", got, err)
	}
	for i, index := range []int{0, _gbfsStatusChunk} {
		want := gbfsStatus{StationID: stations[index].StationID, NumBikesAvailable: 5, NumDocksAvailable: 7, IsInstalled: true, IsRenting: true, IsReturning: true, LastReported: 1700000000}
		if got[i] != want {
			t.Fatalf("status[%d] = %+v, want %+v", i, got[i], want)
		}
	}
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	if got, err := buildGBFSStatuses(t.Context(), rc, stations); err == nil || got != nil {
		t.Fatalf("failed Redis returned %v, error %v", got, err)
	}
}

func TestGBFSStatusRefreshAndCachedHTTPResponse(t *testing.T) {
	rc := gbfsTestRedis(t)
	id := fmt.Sprintf("quality-gbfs-refresh-%d", os.Getpid())
	key, observationKey := shared.BikeAvailabilityKey(id), shared.BikeAvailabilityObservedAtKey(id)
	t.Cleanup(func() { _ = rc.Del(context.Background(), key, observationKey).Err() })
	if err := rc.MSet(t.Context(), key, mustMarshalBikeEta(t, &models.BikeEta{StationUID: id, GeneralBikes: 4, ServiceStatus: 1}), observationKey, "invalid").Err(); err != nil {
		t.Fatal(err)
	}
	cache := &gbfsCache{station: gbfsStationSnapshot{stations: []gbfsStation{{StationID: id}}, expiresAt: time.Now().Add(time.Hour)}}
	got, err := sharedGBFSStatuses(t.Context(), nil, rc, cache)
	if err != nil || len(got.statuses) != 1 || got.statuses[0].LastReported != 0 || got.generatedAt == 0 || !got.expiresAt.After(time.Now()) {
		t.Fatalf("status snapshot = %+v, error %v", got, err)
	}
	if err := rc.Del(t.Context(), key).Err(); err != nil {
		t.Fatal(err)
	}
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/status", handleGBFSStationStatus(nil, rc, cache))
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/status", nil))
	var response struct {
		TTL     int    `json:"ttl"`
		Version string `json:"version"`
		Data    struct {
			Stations []gbfsStatus `json:"stations"`
		} `json:"data"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if recorder.Code != 200 || response.TTL != 30 || response.Version != "2.3" || len(response.Data.Stations) != 1 || response.Data.Stations[0] != got.statuses[0] {
		t.Fatalf("cached HTTP status = %d, body %s", recorder.Code, recorder.Body)
	}
	if again, err := refreshGBFSStatuses(nil, rc, cache); err != nil || len(again.statuses) != 1 {
		t.Fatalf("refresh reused snapshot = %+v, error %v", again, err)
	}
}

func TestGBFSSharedBuildHonorsCallerCancellation(t *testing.T) {
	for _, kind := range []string{"stations", "status"} {
		t.Run(kind, func(t *testing.T) {
			cache := &gbfsCache{}
			block := make(chan struct{})
			started := make(chan struct{})
			result := cache.flight.DoChan(kind, func() (any, error) { close(started); <-block; return nil, errors.New("build failed") })
			<-started
			ctx, cancel := context.WithCancel(t.Context())
			cancel()
			var err error
			if kind == "stations" {
				_, err = sharedGBFSStations(ctx, nil, cache)
			} else {
				_, err = sharedGBFSStatuses(ctx, nil, nil, cache)
			}
			close(block)
			<-result
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled caller error = %v", err)
			}
		})
	}
}

func TestGBFSStationsReadAndShareDatabaseSnapshot(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set")
	}
	admin, err := pgxpool.New(t.Context(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	schema := fmt.Sprintf("quality_gbfs_%d", os.Getpid())
	if _, err := admin.Exec(t.Context(), "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE") }()
	if _, err := admin.Exec(t.Context(), "CREATE TABLE "+schema+".bike_stations (LIKE public.bike_stations INCLUDING ALL)"); err != nil {
		t.Fatal(err)
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	db, err := pgxpool.NewWithConfig(t.Context(), config)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(t.Context(), `INSERT INTO bike_stations(station_uid,station_id,city,name,geom,address,capacity) VALUES ('b','b','Taipei','B',ST_SetSRID(ST_MakePoint(121,25),4326),NULL,0),('a','a','Taipei','A',ST_SetSRID(ST_MakePoint(120,24),4326),'road',10),('no-point','no-point','Taipei','hidden',NULL,NULL,0)`); err != nil {
		t.Fatal(err)
	}
	cache := &gbfsCache{}
	beforeRefresh := time.Now()
	for range 2 {
		got, err := sharedGBFSStations(t.Context(), db, cache)
		if err != nil || len(got) != 2 || got[0] != (gbfsStation{StationID: "a", Name: "A", Lat: 24, Lon: 120, Address: "road", Capacity: 10}) || got[1] != (gbfsStation{StationID: "b", Name: "B", Lat: 25, Lon: 121}) {
			t.Fatalf("station snapshot = %+v, error %v", got, err)
		}
	}
	afterRefresh := time.Now()
	if cache.station.expiresAt.Before(beforeRefresh.Add(time.Hour)) || cache.station.expiresAt.After(afterRefresh.Add(time.Hour)) {
		t.Fatalf("station information expiry = %s, want one-hour refresh lifetime", cache.station.expiresAt)
	}
	db.Close()
	if _, err := sharedGBFSStations(t.Context(), db, &gbfsCache{}); err == nil {
		t.Fatal("closed database accepted")
	}
}

func TestGBFSEmptyStationInventoryDoesNotRequireRedis(t *testing.T) {
	got, err := buildGBFSStatuses(t.Context(), nil, nil)
	if err != nil || got == nil || len(got) != 0 {
		t.Fatalf("empty inventory = %v, error %v", got, err)
	}
}

func TestGBFSPartialReportingDistinguishesCompleteAndMissingData(t *testing.T) {
	rc := gbfsTestRedis(t)
	id := fmt.Sprintf("quality-gbfs-observation-%d", os.Getpid())
	key, observed := shared.BikeAvailabilityKey(id), shared.BikeAvailabilityObservedAtKey(id)
	t.Cleanup(func() { _ = rc.Del(context.Background(), key, observed).Err() })
	if err := rc.MSet(t.Context(), key, mustMarshalBikeEta(t, &models.BikeEta{StationUID: id, GeneralBikes: 4, ServiceStatus: 1}), observed, "1700000000").Err(); err != nil {
		t.Fatal(err)
	}
	core, entries := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	stations := []gbfsStation{{StationID: id}}
	complete, err := buildGBFSStatuses(t.Context(), rc, stations)
	if err != nil || len(complete) != 1 || entries.FilterMessage("partial").Len() != 0 {
		t.Fatalf("complete feed = %v, error %v, warnings %v", complete, err, entries.All())
	}
	if err := rc.Del(t.Context(), key).Err(); err != nil {
		t.Fatal(err)
	}
	missing, err := buildGBFSStatuses(t.Context(), rc, stations)
	partial := entries.FilterMessage("partial").All()
	if err != nil || len(missing) != 0 || len(partial) != 1 {
		t.Fatalf("missing feed = %v, error %v, warnings %v", missing, err, partial)
	}
	fields := partial[0].ContextMap()
	if fields["stations"] != int64(1) || fields["reported"] != int64(0) || fields["component"] != "gbfs" {
		t.Fatalf("partial diagnostic = %v", fields)
	}
}
