package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

const _testMB = 1024 * 1024

func TestTDXPointsTakesTheBindingMeter(t *testing.T) {
	for _, tc := range []struct {
		name         string
		calls, bytes int64
		want         float64
	}{
		{"idle", 0, 0, 0},
		{"one point of calls", 1500, 0, 1},
		{"calls below one point stay fractional", 1499, 0, 1499.0 / 1500},
		{"one point of bytes", 0, 150 * _testMB, 1},
		{"calls bind", 3000, 150 * _testMB, 2},
		{"bytes bind", 1500, 300 * _testMB, 2},
		{"bytes below one point stay fractional", 0, 75 * _testMB, 0.5},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tdxPoints(tc.calls, tc.bytes); got != tc.want {
				t.Fatalf("points=%v want %v", got, tc.want)
			}
		})
	}
}

func TestTDXPointAlertThreshold(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want float64
	}{{"", 15}, {" 20 ", 20}, {"2.5", 2.5}, {"typo", 15}, {"0", 0}, {"-1", -1}} {
		if got := tdxPointAlertThreshold(tc.raw); got != tc.want {
			t.Fatalf("threshold(%q)=%v want %v", tc.raw, got, tc.want)
		}
	}
}

func TestParseTDXUsageSortsNamesByBytes(t *testing.T) {
	report := parseTDXUsage(map[string]string{
		"calls:_total": "9", "not_modified:_total": "2", "bytes:_total": "600",
		"calls:b": "3", "bytes:b": "200", "not_modified:b": "1",
		"calls:a": "4", "bytes:a": "200", "not_modified:a": "1",
		"calls:big": "2", "bytes:big": "200x",
		"calls:c:d": "1", "unknown:c:d": "7",
	})
	want := tdxUsageReport{
		total: tdxNameUsage{name: "_total", calls: 9, notModified: 2, bytes: 600},
		names: []tdxNameUsage{
			{name: "a", calls: 4, notModified: 1, bytes: 200},
			{name: "b", calls: 3, notModified: 1, bytes: 200},
			{name: "big", calls: 2},
			{name: "c:d", calls: 1},
		},
	}
	if !reflect.DeepEqual(report, want) {
		t.Fatalf("report=%+v want %+v", report, want)
	}
	if empty := parseTDXUsage(nil); empty.total.name != shared.TDXUsageTotal || empty.names != nil {
		t.Fatalf("empty=%+v", empty)
	}
}

func usageTestRedis(t *testing.T, day string) *redis.Client {
	t.Helper()
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 13})
	keys := []string{shared.TDXUsageKey(day), tdxUsageAlertedKey(day)}
	rc.Del(context.Background(), keys...)
	t.Cleanup(func() { rc.Del(context.Background(), keys...); _ = rc.Close() })
	return rc
}

func closedUsageRedis() *redis.Client {
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	return rc
}

// seedUsage writes per-name calls and bytes plus the matching day totals.
func seedUsage(t *testing.T, rc *redis.Client, day string, usage map[string][2]int64) {
	t.Helper()
	fields := map[string]any{}
	var calls, size int64
	for name, u := range usage {
		fields[shared.TDXUsageField(shared.TDXUsageCalls, name)] = u[0]
		fields[shared.TDXUsageField(shared.TDXUsageBytes, name)] = u[1]
		calls += u[0]
		size += u[1]
	}
	fields[shared.TDXUsageField(shared.TDXUsageCalls, shared.TDXUsageTotal)] = calls
	fields[shared.TDXUsageField(shared.TDXUsageBytes, shared.TDXUsageTotal)] = size
	if err := rc.HSet(context.Background(), shared.TDXUsageKey(day), fields).Err(); err != nil {
		t.Fatal(err)
	}
}

func TestReadTDXUsageTotal(t *testing.T) {
	rc := usageTestRedis(t, "2030-02-01")
	total, err := readTDXUsageTotal(context.Background(), rc, "2030-02-01")
	if err != nil || total != (tdxNameUsage{name: shared.TDXUsageTotal}) {
		t.Fatalf("missing day=%+v/%v", total, err)
	}
	seedUsage(t, rc, "2030-02-01", map[string][2]int64{"bus": {12, 3400}})
	total, err = readTDXUsageTotal(context.Background(), rc, "2030-02-01")
	if err != nil || total != (tdxNameUsage{name: shared.TDXUsageTotal, calls: 12, bytes: 3400}) {
		t.Fatalf("seeded day=%+v/%v", total, err)
	}
	if _, err := readTDXUsageTotal(context.Background(), closedUsageRedis(), "2030-02-01"); err == nil {
		t.Fatal("closed Redis error lost")
	}
	if _, err := readTDXUsage(context.Background(), closedUsageRedis(), "2030-02-01"); err == nil {
		t.Fatal("closed Redis error lost")
	}
}

type webhookRecorder struct {
	mu       sync.Mutex
	status   int
	contents []string
	types    []string
}

func newWebhook(t *testing.T, status int) (*webhookRecorder, *httptest.Server) {
	t.Helper()
	hook := &webhookRecorder{status: status}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Content string `json:"content"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		hook.mu.Lock()
		hook.contents = append(hook.contents, payload.Content)
		hook.types = append(hook.types, r.Header.Get("Content-Type"))
		hook.mu.Unlock()
		w.WriteHeader(hook.status)
	}))
	t.Cleanup(srv.Close)
	return hook, srv
}

func (h *webhookRecorder) posts() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.contents...)
}

func testAlert(rc redis.Cmdable, webhook string, threshold float64) tdxUsageAlert {
	return tdxUsageAlert{rc: rc, client: &http.Client{Timeout: time.Second}, webhook: webhook, threshold: threshold}
}

func TestTDXUsageAlertPostsOncePerDayAtThreshold(t *testing.T) {
	const day = "2030-02-02"
	rc := usageTestRedis(t, day)
	hook, srv := newWebhook(t, http.StatusNoContent)
	usage := map[string][2]int64{"n1": {1490, 60 * _testMB}, "n2": {1, 50 * _testMB}, "n3": {1, 4 * _testMB}}
	seedUsage(t, rc, day, usage)
	alert := testAlert(rc, srv.URL, 1)
	if err := alert.run(context.Background(), day); err != nil || len(hook.posts()) != 0 {
		t.Fatalf("below threshold err=%v posts=%v", err, hook.posts())
	}
	// Exactly 1,500 calls: the calls meter reaches the threshold on its own.
	for i := range 4 {
		usage["n"+strconv.Itoa(i+4)] = [2]int64{2, int64(i+1) * _testMB}
	}
	seedUsage(t, rc, day, usage)
	for range 2 {
		if err := alert.run(context.Background(), day); err != nil {
			t.Fatal(err)
		}
	}
	posts := hook.posts()
	want := "TDX usage on 2030-02-02 (Taipei) so far: about 1.0 points, alert threshold 1. 1500 calls, 124.0 MB." +
		"\n- n1: 60.0 MB, 1490 calls, 0 not modified" +
		"\n- n2: 50.0 MB, 1 calls, 0 not modified" +
		"\n- n3: 4.0 MB, 1 calls, 0 not modified" +
		"\n- n7: 4.0 MB, 2 calls, 0 not modified" +
		"\n- n6: 3.0 MB, 2 calls, 0 not modified"
	if len(posts) != 1 || posts[0] != want || hook.types[0] != "application/json" {
		t.Fatalf("posts=%q types=%v", posts, hook.types)
	}
	if ttl := rc.TTL(context.Background(), tdxUsageAlertedKey(day)).Val(); ttl <= 47*time.Hour || ttl > 48*time.Hour {
		t.Fatalf("flag ttl=%s", ttl)
	}
}

func TestTDXUsageAlertDisabledAtZeroThreshold(t *testing.T) {
	for _, threshold := range []float64{0, -1} {
		if err := testAlert(closedUsageRedis(), "", threshold).run(context.Background(), "2030-02-03"); err != nil {
			t.Fatalf("threshold %v touched Redis: %v", threshold, err)
		}
	}
	if err := testAlert(closedUsageRedis(), "", 1).run(context.Background(), "2030-02-03"); err == nil {
		t.Fatal("closed Redis error lost")
	}
}

func TestTDXUsageAlertWithoutWebhookLogsOnce(t *testing.T) {
	const day = "2030-02-04"
	core, logs := observer.New(zap.WarnLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	rc := usageTestRedis(t, day)
	seedUsage(t, rc, day, map[string][2]int64{"bus": {3000, 0}})
	for range 2 {
		if err := testAlert(rc, "", 2).run(context.Background(), day); err != nil {
			t.Fatal(err)
		}
	}
	entries := logs.FilterMessage("daily points over threshold").All()
	if len(entries) != 1 {
		t.Fatalf("logs=%v", logs.All())
	}
	if fields := entries[0].ContextMap(); fields["points"] != 2.0 || fields["threshold"] != 2.0 || fields["webhook"] != false || fields["day"] != day {
		t.Fatalf("fields=%v", fields)
	}
}

func TestTDXUsageAlertReleasesFlagWhenPostFails(t *testing.T) {
	const day = "2030-02-05"
	rc := usageTestRedis(t, day)
	seedUsage(t, rc, day, map[string][2]int64{"bus": {1500, 0}})
	failing, failingSrv := newWebhook(t, http.StatusMultipleChoices)
	closedSrv := httptest.NewServer(http.NotFoundHandler())
	closedSrv.Close()
	for _, webhook := range []string{failingSrv.URL, "://bad", closedSrv.URL} {
		if err := testAlert(rc, webhook, 1).run(context.Background(), day); err == nil {
			t.Fatalf("webhook %s failure lost", webhook)
		}
		if n := rc.Exists(context.Background(), tdxUsageAlertedKey(day)).Val(); n != 0 {
			t.Fatalf("webhook %s kept the flag", webhook)
		}
	}
	if len(failing.posts()) != 1 {
		t.Fatalf("posts=%v", failing.posts())
	}
	ok, okSrv := newWebhook(t, http.StatusOK)
	if err := testAlert(rc, okSrv.URL, 1).run(context.Background(), day); err != nil || len(ok.posts()) != 1 {
		t.Fatalf("retry err=%v posts=%v", err, ok.posts())
	}
}

// usageRedisFault fails one command of an otherwise working client.
type usageRedisFault struct {
	redis.Cmdable

	failSetNX bool
}

func (f usageRedisFault) SetNX(ctx context.Context, key string, value any, ttl time.Duration) *redis.BoolCmd {
	if !f.failSetNX {
		return f.Cmdable.SetNX(ctx, key, value, ttl)
	}
	cmd := redis.NewBoolCmd(ctx)
	cmd.SetErr(errors.New("setnx unavailable"))
	return cmd
}

func (f usageRedisFault) HGetAll(ctx context.Context, key string) *redis.MapStringStringCmd {
	cmd := redis.NewMapStringStringCmd(ctx)
	cmd.SetErr(errors.New("hgetall unavailable"))
	return cmd
}

func TestTDXUsageAlertRedisFailures(t *testing.T) {
	const day = "2030-02-06"
	rc := usageTestRedis(t, day)
	seedUsage(t, rc, day, map[string][2]int64{"bus": {1500, 0}})
	hook, srv := newWebhook(t, http.StatusOK)
	if err := testAlert(usageRedisFault{Cmdable: rc, failSetNX: true}, srv.URL, 1).run(context.Background(), day); err == nil || !strings.Contains(err.Error(), "setnx unavailable") {
		t.Fatalf("setnx err=%v", err)
	}
	if err := testAlert(usageRedisFault{Cmdable: rc}, srv.URL, 1).run(context.Background(), day); err == nil || !strings.Contains(err.Error(), "hgetall unavailable") {
		t.Fatalf("hgetall err=%v", err)
	}
	if n := rc.Exists(context.Background(), tdxUsageAlertedKey(day)).Val(); n != 0 || len(hook.posts()) != 0 {
		t.Fatalf("flag=%d posts=%v", n, hook.posts())
	}
}

func TestCheckTDXUsageReadsEnvAndLogsFailure(t *testing.T) {
	now := time.Date(2030, 2, 6, 17, 0, 0, 0, time.UTC)
	rc := usageTestRedis(t, "2030-02-07")
	seedUsage(t, rc, "2030-02-07", map[string][2]int64{"bus": {1500, 0}})
	hook, srv := newWebhook(t, http.StatusOK)
	t.Setenv("ALERT_WEBHOOK_URL", srv.URL)
	t.Setenv("TDX_DAILY_POINT_ALERT", "1")
	checkTDXUsage(rc, now)
	if posts := hook.posts(); len(posts) != 1 || !strings.Contains(posts[0], "2030-02-07") {
		t.Fatalf("posts=%v", posts)
	}
	core, logs := observer.New(zap.WarnLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	checkTDXUsage(closedUsageRedis(), now)
	if logs.FilterMessage("check failed").Len() != 1 {
		t.Fatalf("logs=%v", logs.All())
	}
}

func TestLogTDXUsageReportsPreviousTaipeiDay(t *testing.T) {
	core, logs := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	rc := usageTestRedis(t, "2030-02-08")
	seedUsage(t, rc, "2030-02-08", map[string][2]int64{"bus": {10, 300 * _testMB}, "bike": {20, 5}})
	logTDXUsage(rc, time.Date(2030, 2, 8, 16, 30, 0, 0, time.UTC))
	var got []map[string]any
	for _, entry := range logs.FilterMessage("daily usage").All() {
		got = append(got, entry.ContextMap())
	}
	line := func(event, name string, calls, size int64, points float64) map[string]any {
		return map[string]any{"component": "tdx", "action": "usage_report", "event": event, "day": "2030-02-08",
			"name": name, "calls": calls, "not_modified": int64(0), "bytes": size, "points": points}
	}
	want := []map[string]any{
		line("name_total", "bus", 10, 300*_testMB, 2),
		line("name_total", "bike", 20, 5, 20.0/1500),
		line("day_total", shared.TDXUsageTotal, 30, 300*_testMB+5, tdxPoints(30, 300*_testMB+5)),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("lines=%v want %v", got, want)
	}
	logTDXUsage(closedUsageRedis(), time.Now())
	if logs.FilterMessage("report failed").Len() != 1 {
		t.Fatalf("logs=%v", logs.All())
	}
}

func TestTDXUsageCronsRunAndTouchHealth(t *testing.T) {
	core, logs := observer.New(zap.WarnLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	t.Setenv("TDX_DAILY_POINT_ALERT", "")
	workerContractHealth(t, filepath.Join(t.TempDir(), "healthy"))
	r := cron.New(cron.WithSeconds())
	registerTDXUsageCrons(r, closedUsageRedis())
	entries := r.Entries()
	if len(entries) != 2 {
		t.Fatalf("entries=%d", len(entries))
	}
	for _, entry := range entries {
		entry.Job.Run()
	}
	if logs.FilterMessage("check failed").Len() != 1 || logs.FilterMessage("report failed").Len() != 1 {
		t.Fatalf("logs=%v", logs.All())
	}
	if _, err := os.Stat(_health.path); err != nil {
		t.Fatal(err)
	}
}
