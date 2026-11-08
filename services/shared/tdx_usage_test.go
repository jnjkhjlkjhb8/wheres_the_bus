package shared

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestTDXUsageKeyFieldAndTaipeiDay(t *testing.T) {
	if got := TDXUsageKey("2026-11-08"); got != "shared:tdx:usage:2026-11-08" {
		t.Fatalf("key=%s", got)
	}
	if got := TDXUsageField(TDXUsageBytes, "bus_x"); got != "bytes:bus_x" {
		t.Fatalf("field=%s", got)
	}
	for _, tc := range []struct {
		at   time.Time
		want string
	}{
		{time.Date(2026, 11, 7, 15, 59, 59, 0, time.UTC), "2026-11-07"},
		{time.Date(2026, 11, 7, 16, 0, 0, 0, time.UTC), "2026-11-08"},
	} {
		if got := TDXUsageDay(tc.at); got != tc.want {
			t.Fatalf("day(%s)=%s want %s", tc.at, got, tc.want)
		}
	}
}

func TestTDXUsageInstalledOnlyForRedisStore(t *testing.T) {
	plain := NewTDXClient(TDXConfig{Store: newMemTDXStore(), IMSKey: legacyIMSKey})
	if _, ok := plain.http.GetClient().Transport.(tdxUsageTransport); ok {
		t.Fatal("usage counted without a Redis store")
	}
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	t.Cleanup(func() { _ = rc.Close() })
	counted := NewTDXClient(TDXConfig{Store: RedisTDXStore{RC: rc}, IMSKey: legacyIMSKey})
	transport, ok := counted.http.GetClient().Transport.(tdxUsageTransport)
	if !ok || transport.base == nil || transport.record == nil {
		t.Fatalf("transport=%#v", counted.http.GetClient().Transport)
	}
}

type tdxUsageCapture struct {
	mu   sync.Mutex
	seen []tdxUsage
}

func (c *tdxUsageCapture) record(u tdxUsage) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.seen = append(c.seen, u)
}

func countedTDXClient(t *testing.T, baseURL string, base http.RoundTripper) (*TDXClient, *tdxUsageCapture) {
	t.Helper()
	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: baseURL})
	client.retryWait = time.Nanosecond
	client.retryMaxWait = time.Nanosecond
	if base == nil {
		base = client.http.GetClient().Transport
	}
	capture := &tdxUsageCapture{}
	client.http.SetTransport(tdxUsageTransport{base: base, record: capture.record})
	return client, capture
}

func TestTDXUsageCountsCompressedBytesOfEveryAttempt(t *testing.T) {
	var compressed bytes.Buffer
	zw := gzip.NewWriter(&compressed)
	_, _ = zw.Write(bytes.Repeat([]byte(`{"StopName":"Taipei Main Station"},`), 200))
	_ = zw.Close()
	var attempts int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts++
		switch attempts {
		case 1:
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte("slow down"))
		case 2:
			w.Header().Set("Content-Encoding", "gzip")
			w.Header().Set("Last-Modified", "MARKER")
			_, _ = w.Write(compressed.Bytes())
		default:
			w.WriteHeader(http.StatusNotModified)
		}
	}))
	defer srv.Close()
	client, capture := countedTDXClient(t, srv.URL, nil)

	fetch, err := client.Get(context.Background(), "/eta", "bus_eta")
	if err != nil {
		t.Fatal(err)
	}
	// Closing unread still counts the whole body: Close drains it first.
	if err := fetch.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetInto(context.Background(), "/fare", "rail_fare", nil); err != nil {
		t.Fatal(err)
	}
	want := []tdxUsage{
		{name: "bus_eta", bytes: int64(len("slow down"))},
		{name: "bus_eta", bytes: int64(compressed.Len())},
		{name: "rail_fare", notModified: 1},
	}
	if !reflect.DeepEqual(capture.seen, want) {
		t.Fatalf("usage=%+v want %+v", capture.seen, want)
	}
}

func TestTDXUsageCountsAttemptWithoutResponse(t *testing.T) {
	cause := errors.New("connection reset")
	client, capture := countedTDXClient(t, "https://tdx.invalid", tdxRoundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, cause
	}))
	client.maxRetries = 1
	if _, err := client.Get(context.Background(), "/eta", "bike_x"); !errors.Is(err, cause) {
		t.Fatalf("err=%v", err)
	}
	want := []tdxUsage{{name: "bike_x"}, {name: "bike_x"}}
	if !reflect.DeepEqual(capture.seen, want) {
		t.Fatalf("usage=%+v want %+v", capture.seen, want)
	}
}

func TestTDXCountingBodyRecordsOnceAndKeepsCloseError(t *testing.T) {
	body := newTrackingResponseBody("abc")
	body.closeErr = errors.New("close failed")
	capture := &tdxUsageCapture{}
	counted := &tdxCountingBody{ReadCloser: body, usage: tdxUsage{name: "x"}, record: capture.record}
	buf := make([]byte, 2)
	if n, err := counted.Read(buf); n != 2 || err != nil {
		t.Fatalf("read=%d/%v", n, err)
	}
	for range 2 {
		if err := counted.Close(); !errors.Is(err, body.closeErr) {
			t.Fatalf("close err=%v", err)
		}
	}
	if want := []tdxUsage{{name: "x", bytes: 2}}; !reflect.DeepEqual(capture.seen, want) {
		t.Fatalf("usage=%+v want %+v", capture.seen, want)
	}
}

func TestTDXUsageRecorderWritesTaipeiDayHash(t *testing.T) {
	rc := redis.NewClient(&redis.Options{Addr: envOrSkip(t, "REDIS_TEST_ADDR"), DB: 11})
	key := TDXUsageKey("2030-01-02")
	t.Cleanup(func() { rc.Del(context.Background(), key); _ = rc.Close() })
	rc.Del(context.Background(), key)
	recorder := tdxUsageRecorder{rc: rc, now: func() time.Time { return time.Date(2030, 1, 1, 16, 30, 0, 0, time.UTC) }}
	recorder.record(tdxUsage{name: "bus_eta", bytes: 700})
	recorder.record(tdxUsage{name: "bus_eta", notModified: 1, bytes: 5})
	recorder.record(tdxUsage{name: "bike", bytes: 40})
	got, err := rc.HGetAll(context.Background(), key).Result()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"calls:bus_eta": "2", "not_modified:bus_eta": "1", "bytes:bus_eta": "705",
		"calls:bike": "1", "not_modified:bike": "0", "bytes:bike": "40",
		"calls:_total": "3", "not_modified:_total": "1", "bytes:_total": "745",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("hash=%v want %v", got, want)
	}
	if ttl := rc.TTL(context.Background(), key).Val(); ttl <= 8*24*time.Hour-time.Minute || ttl > 8*24*time.Hour {
		t.Fatalf("ttl=%s", ttl)
	}
}

func TestTDXUsageRecorderLogsRedisFailure(t *testing.T) {
	core, logs := observer.New(zap.WarnLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	tdxUsageRecorder{rc: rc, now: time.Now}.record(tdxUsage{name: "bus_eta"})
	entries := logs.FilterMessage("record failed").FilterField(zap.String("name", "bus_eta")).All()
	if len(entries) != 1 {
		t.Fatalf("logs=%v", logs.All())
	}
}
