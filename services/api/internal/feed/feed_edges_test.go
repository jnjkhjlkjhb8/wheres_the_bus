package feed

import (
	"context"
	"crypto/tls"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestGBFSStationRowsDiscardIncompleteSnapshots(t *testing.T) {
	for _, terminal := range []bool{false, true} {
		db, err := pgxmock.NewPool()
		if err != nil {
			t.Fatal(err)
		}
		want := errors.New("station snapshot interrupted")
		rows := pgxmock.NewRows([]string{"station_uid", "name", "lat", "lon", "address", "capacity"}).AddRow("S1", "Station", 25.0, 121.0, "Address", int32(12))
		if terminal {
			rows.CloseError(want)
		} else {
			rows.RowError(0, want)
		}
		db.ExpectQuery("FROM bike_stations").WillReturnRows(rows).RowsWillBeClosed()
		got, err := gbfsStations(t.Context(), db)
		if got != nil || !errors.Is(err, want) {
			t.Fatalf("incomplete snapshot = %v, error %v", got, err)
		}
		if err := db.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
		db.Close()
	}
}

func TestGBFSInformationServesCachedStationsAndReportsDatabaseFailure(t *testing.T) {
	gin.SetMode(gin.TestMode)
	stations := []gbfsStation{{StationID: "S1", Name: "Station", Lat: 25, Lon: 121}}
	cache := &gbfsCache{station: gbfsStationSnapshot{stations: stations, expiresAt: time.Now().Add(time.Hour)}}
	router := gin.New()
	router.GET("/information", handleGBFSStationInformation(nil, cache))
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/information", nil))
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"station_id":"S1"`) {
		t.Fatalf("cached information status = %d, body %s", response.Code, response.Body)
	}
	if got, err := refreshGBFSStations(nil, cache); err != nil || !reflect.DeepEqual(got, stations) {
		t.Fatalf("rechecked station snapshot = %v, error %v", got, err)
	}
	db, err := pgxpool.New(t.Context(), "postgres://quality@127.0.0.1:1/quality?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	router = gin.New()
	router.GET("/information", handleGBFSStationInformation(db, &gbfsCache{}))
	response = httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/information", nil))
	if response.Code != http.StatusInternalServerError || !strings.Contains(response.Body.String(), "station information unavailable") {
		t.Fatalf("failed information status = %d, body %s", response.Code, response.Body)
	}
	if got, err := refreshGBFSStatuses(db, nil, &gbfsCache{}); err == nil || got.statuses != nil {
		t.Fatalf("failed stations produced status snapshot = %+v, error %v", got, err)
	}
}

func TestGBFSStatusFailureDoesNotPublishPartialSnapshot(t *testing.T) {
	rc := gbfsTestRedis(t)
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	cache := &gbfsCache{station: gbfsStationSnapshot{stations: []gbfsStation{{StationID: "S1"}}, expiresAt: time.Now().Add(time.Hour)}}
	got, err := sharedGBFSStatuses(t.Context(), nil, rc, cache)
	if err == nil || got.statuses != nil || cache.status.generatedAt != 0 {
		t.Fatalf("failed status build = %+v, error %v, cache %+v", got, err, cache.status)
	}
}

func TestGBFSDiscoveryUsesTLSAndForwardedScheme(t *testing.T) {
	for _, tc := range []struct {
		tls       bool
		forwarded string
		host      string
		want      string
	}{
		{true, "", "bus.test", "https://bus.test:8080"},
		{false, "", "bus.test:9090", "http://bus.test:9090"},
		{true, "http", "bus.test", "http://bus.test"},
	} {
		request := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "http://"+tc.host, nil)
		if tc.tls {
			request.TLS = &tls.ConnectionState{}
		}
		request.Header.Set("X-Forwarded-Proto", tc.forwarded)
		if got := requestBaseURL(request, "8080"); got != tc.want {
			t.Fatalf("discovery base = %q, want %q", got, tc.want)
		}
	}
}
