package weather

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	_validObservationJSON = `{"records":{"Station":[{"GeoInfo":{"CountyName":"臺北市"},"ObsTime":{"DateTime":"2026-07-15T03:00:00+08:00"},"WeatherElement":{"AirTemperature":"30","WindSpeed":"2","RelativeHumidity":"70"}}]}}`
	_validRainJSON        = `{"records":{"Station":[{"GeoInfo":{"CountyName":"臺北市"},"ObsTime":{"DateTime":"2026-07-15T03:00:00+08:00"},"RainfallElement":{"Now":{"Precipitation":"1.5"}}}]}}`
)

func weatherServer(t *testing.T, obsStatus int, obsBody, rainBody string, delay time.Duration) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if delay > 0 {
			time.Sleep(delay)
		}
		if r.URL.Path == "/O-A0003-001" {
			w.WriteHeader(obsStatus)
			_, _ = w.Write([]byte(obsBody))
			return
		}
		_, _ = w.Write([]byte(rainBody))
	}))
}

func TestFetchWeatherSnapshotReturnsHTTPStatusError(t *testing.T) {
	server := weatherServer(t, http.StatusServiceUnavailable, "unavailable", _validRainJSON, 0)
	defer server.Close()
	if _, err := fetchWeatherSnapshot(context.Background(), server.Client(), server.URL, "key"); err == nil {
		t.Fatal("HTTP 503 returned nil error")
	}
}

func TestFetchWeatherSnapshotReturnsParseError(t *testing.T) {
	server := weatherServer(t, http.StatusOK, `{"records":`, _validRainJSON, 0)
	defer server.Close()
	if _, err := fetchWeatherSnapshot(context.Background(), server.Client(), server.URL, "key"); err == nil {
		t.Fatal("malformed observation JSON returned nil error")
	}
}

func TestFetchWeatherSnapshotHonorsContext(t *testing.T) {
	server := weatherServer(t, http.StatusOK, _validObservationJSON, _validRainJSON, 40*time.Millisecond)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Millisecond)
	defer cancel()
	_, err := fetchWeatherSnapshot(ctx, server.Client(), server.URL, "key")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("fetch error = %v, want deadline exceeded", err)
	}
}

func TestWriteWeatherSnapshotReturnsRedisError(t *testing.T) {
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", DialTimeout: 20 * time.Millisecond, ReadTimeout: 20 * time.Millisecond, WriteTimeout: 20 * time.Millisecond})
	defer func() { _ = rc.Close() }()
	err := writeWeatherSnapshot(context.Background(), rc, map[string]Data{"Taipei": {Temperature: 30}})
	if err == nil {
		t.Fatal("Redis connection failure returned nil error")
	}
}
