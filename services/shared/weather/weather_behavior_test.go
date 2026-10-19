package weather

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
)

func observation(county, stamp, temperature, wind, humidity string) string {
	return fmt.Sprintf(`{"GeoInfo":{"CountyName":%q},"ObsTime":{"DateTime":%q},"WeatherElement":{"AirTemperature":%q,"WindSpeed":%q,"RelativeHumidity":%q}}`, county, stamp, temperature, wind, humidity)
}

func rain(county, stamp, amount string) string {
	return fmt.Sprintf(`{"GeoInfo":{"CountyName":%q},"ObsTime":{"DateTime":%q},"RainfallElement":{"Now":{"Precipitation":%q}}}`, county, stamp, amount)
}

func feed(stations ...string) []byte {
	return []byte(`{"records":{"Station":[` + strings.Join(stations, ",") + `]}}`)
}

func TestObservationChoosesLatestUsableStation(t *testing.T) {
	old, newer := "2026-07-15T02:00:00+08:00", "2026-07-15T03:00:00+08:00"
	body := feed(
		observation("unknown", "bad", "bad", "bad", "bad"),
		observation("臺北市", old, "20", "1", "60"),
		observation("臺北市", newer, "30", "2", "70"),
		observation("臺北市", old, "bad", "bad", "bad"),
		observation("臺北市", newer, "40", "3", "80"),
		observation("新北市", newer, "-90", "-90", "-90"),
		observation("臺南市", newer, "-91", "2", "70"),
		observation("高雄市", newer, "20", "-91", "70"),
		observation("臺中市", newer, "20", "2", "-91"),
	)
	got, err := parseObservations(body)
	want := map[string]Data{"Taipei": {Temperature: 30, WindSpeed: 2, Humidity: 70}, "NewTaipei": {Temperature: -90, WindSpeed: -90, Humidity: -90}}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("observations=%v error=%v want=%v", got, err, want)
	}
	for _, station := range []string{
		observation("臺北市", "bad", "20", "1", "60"),
		observation("臺北市", old, "bad", "1", "60"),
		observation("臺北市", old, "20", "bad", "60"),
		observation("臺北市", old, "20", "1", "bad"),
	} {
		if result, err := parseObservations(feed(station)); result != nil || err == nil {
			t.Fatalf("invalid station result=%v error=%v", result, err)
		}
	}
	if result, err := parseObservations([]byte(`bad`)); result != nil || err == nil {
		t.Fatalf("invalid envelope result=%v error=%v", result, err)
	}
}

func TestRainfallLatestTieAndSentinel(t *testing.T) {
	old, newer := "2026-07-15T02:00:00+08:00", "2026-07-15T03:00:00+08:00"
	body := feed(rain("unknown", "bad", "bad"), rain("臺北市", old, "1"), rain("臺北市", newer, "2"), rain("臺北市", old, "8"), rain("臺北市", newer, "9"), rain("新北市", newer, "0"), rain("臺南市", newer, "-1"))
	got, err := parseRainfall(body)
	if err != nil || !reflect.DeepEqual(got, map[string]float64{"Taipei": 2, "NewTaipei": 0}) {
		t.Fatalf("rainfall=%v error=%v", got, err)
	}
	for _, body := range [][]byte{[]byte(`bad`), feed(rain("臺北市", "bad", "1")), feed(rain("臺北市", newer, "bad"))} {
		if result, err := parseRainfall(body); result != nil || err == nil {
			t.Fatalf("invalid rainfall result=%v error=%v", result, err)
		}
	}
}

func TestFetchSnapshotRequestsBothFeedsAndMergesCities(t *testing.T) {
	var requests []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.Header.Get("Authorization") != "test-key" {
			t.Errorf("request method=%s auth=%q", r.Method, r.Header.Get("Authorization"))
		}
		requests = append(requests, r.URL.Path)
		if r.URL.Path == "/O-A0003-001" {
			_, _ = w.Write([]byte(_validObservationJSON))
			return
		}
		_, _ = w.Write(feed(rain("臺北市", "2026-07-15T03:00:00+08:00", "1.5"), rain("新北市", "2026-07-15T03:00:00+08:00", "3")))
	}))
	defer server.Close()
	got, err := fetchWeatherSnapshot(context.Background(), server.Client(), server.URL, "test-key")
	want := map[string]Data{"Taipei": {Temperature: 30, WindSpeed: 2, Humidity: 70, Precipitation: 1.5}}
	if err != nil || !reflect.DeepEqual(got, want) || !reflect.DeepEqual(requests, []string{"/O-A0003-001", "/O-A0002-001"}) {
		t.Fatalf("snapshot=%v requests=%v error=%v", got, requests, err)
	}
}

func TestSnapshotRejectsMissingDependenciesAndRainFailures(t *testing.T) {
	if _, err := fetchWeatherSnapshot(nil, http.DefaultClient, "invalid", "key"); err == nil { //nolint:staticcheck // This exercises rejection of a nil context.
		t.Fatal("nil context accepted")
	}
	if _, err := fetchWeatherSnapshot(context.Background(), nil, "invalid", "key"); err == nil {
		t.Fatal("nil client accepted")
	}
	for _, tc := range []struct {
		obs, rain string
		status    int
	}{
		{_validObservationJSON, _validRainJSON, http.StatusBadGateway},
		{_validObservationJSON, `bad`, http.StatusOK},
		{`{"records":{"Station":[]}}`, _validRainJSON, http.StatusOK},
	} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/O-A0003-001" {
				_, _ = w.Write([]byte(tc.obs))
				return
			}
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(tc.rain))
		}))
		result, err := fetchWeatherSnapshot(context.Background(), server.Client(), server.URL, "key")
		server.Close()
		if result != nil || err == nil {
			t.Fatalf("failed snapshot=%v error=%v", result, err)
		}
	}
	if _, err := fetchCWA(context.Background(), http.DefaultClient, "://bad", "key"); err == nil {
		t.Fatal("invalid URL accepted")
	}
}

func TestWeatherJSONRejectsAdditionalValues(t *testing.T) {
	for _, body := range []string{`{} {}`, `{} broken`, `broken`} {
		var target any
		if err := decodeWeatherJSON([]byte(body), &target); err == nil {
			t.Fatalf("accepted body %q", body)
		}
	}
	var target any
	if err := decodeWeatherJSON([]byte(`{} `), &target); err != nil {
		t.Fatal(err)
	}
}

func TestWriteWeatherSnapshotEncodesValuesAndSetsTTL(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, MaxRetries: -1})
	defer rc.Close()
	city := fmt.Sprintf("quality_weather_%d_%s", os.Getpid(), t.Name())
	key := shared.WeatherKey(city)
	ctx := context.Background()
	defer rc.Del(ctx, key)
	want := Data{Temperature: 23.4, Precipitation: 1.2, WindSpeed: 3.4, Humidity: 56}
	if err := writeWeatherSnapshot(ctx, rc, map[string]Data{city: want}); err != nil {
		t.Fatal(err)
	}
	var got Data
	if err := json.Unmarshal([]byte(rc.Get(ctx, key).Val()), &got); err != nil || got != want {
		t.Fatalf("stored weather=%v error=%v", got, err)
	}
	if ttl := rc.TTL(ctx, key).Val(); ttl < time.Hour-time.Second || ttl > time.Hour {
		t.Fatalf("weather TTL=%v", ttl)
	}
	if err := writeWeatherSnapshot(ctx, rc, map[string]Data{city: {Temperature: math.NaN()}}); err == nil {
		t.Fatal("nonfinite weather silently written")
	}
	if value := rc.Get(ctx, key).Val(); value == "" {
		t.Fatal("failed serialization discarded previous weather")
	}
}

func TestSyncDisabledOrMissingRedis(t *testing.T) {
	t.Setenv("CWA_API_KEY", "")
	if err := Sync(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CWA_API_KEY", "test-key")
	if err := Sync(context.Background(), nil); err == nil {
		t.Fatal("enabled sync accepted missing Redis")
	}
}

func TestSyncHonorsCanceledContextBeforeRedisWrite(t *testing.T) {
	t.Setenv("CWA_API_KEY", "test-key")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	defer func() { _ = rc.Close() }()
	if err := Sync(ctx, rc); !errors.Is(err, context.Canceled) {
		t.Fatalf("sync error=%v, want canceled", err)
	}
}
