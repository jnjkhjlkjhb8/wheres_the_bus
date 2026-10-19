package bike

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
	"strings"
	"testing"
	"time"
)

func TestBikeHistorySamplerFirstSampleAlways(t *testing.T) {
	var s bikeHistorySampler
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)
	if !s.shouldSample("A", now) {
		t.Fatal("first observation of a station should always sample")
	}
}

func TestBikeHistorySamplerGatesWithinInterval(t *testing.T) {
	var s bikeHistorySampler
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)
	if !s.shouldSample("A", now) {
		t.Fatal("first sample expected true")
	}
	// Any observation before 5 minutes elapse must be rejected.
	if s.shouldSample("A", now.Add(_bikeHistorySampleInterval-time.Second)) {
		t.Fatal("sample within the 5-minute interval should be gated")
	}
	if s.shouldSample("A", now.Add(30*time.Second)) {
		t.Fatal("30s-later sample (a later cron round) should be gated")
	}
}

func TestBikeHistorySamplerAcceptsAfterInterval(t *testing.T) {
	var s bikeHistorySampler
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)
	s.shouldSample("A", now)
	// Exactly the interval later is accepted (>= interval means the gap has passed).
	if !s.shouldSample("A", now.Add(_bikeHistorySampleInterval)) {
		t.Fatal("sample at exactly the interval boundary should be accepted")
	}
}

func TestBikeHistorySamplerPerStationIndependent(t *testing.T) {
	var s bikeHistorySampler
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)
	if !s.shouldSample("A", now) {
		t.Fatal("station A first sample expected true")
	}
	// A different station is gated independently; A's recent sample must not
	// suppress B's first sample.
	if !s.shouldSample("B", now) {
		t.Fatal("station B first sample should be independent of A")
	}
}

func TestBikeHistorySamplerAdvancesLastOnAccept(t *testing.T) {
	var s bikeHistorySampler
	base := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)
	s.shouldSample("A", base)
	accepted := base.Add(_bikeHistorySampleInterval)
	if !s.shouldSample("A", accepted) {
		t.Fatal("sample at interval boundary should be accepted")
	}
	// The gate should now be measured from the accepted time, not the original.
	if s.shouldSample("A", accepted.Add(time.Minute)) {
		t.Fatal("gate should advance to the last accepted sample time")
	}
}

func TestBikeHistorySamplingRequiresStorageAndCombinesRentableCounts(t *testing.T) {
	var rows [][]any
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, time.FixedZone("Taipei", 8*60*60))
	temp := bikeAvailability{StationUID: fmt.Sprintf("quality-bike-%d", time.Now().UnixNano()), AvailableReturnBikes: 7}
	temp.AvailableRentBikesDetail.GeneralBikes = 3
	temp.AvailableRentBikesDetail.ElectricBikes = 2
	sampleBikeHistory(nil, temp, now, &rows)
	if len(rows) != 0 {
		t.Fatal("disabled storage sampled history")
	}
	// Sampling only checks pool availability; it does not issue a database request.
	pool := &pgxpool.Pool{}
	sampleBikeHistory(pool, temp, now, &rows)
	sampleBikeHistory(pool, temp, now.Add(time.Minute), &rows)
	if len(rows) != 1 || rows[0][0] != temp.StationUID || rows[0][1] != 5 || rows[0][2] != 7 || rows[0][3] != now {
		t.Fatalf("sample rows=%v", rows)
	}
	sampleBikeHistory(pool, temp, now.Add(5*time.Minute), &rows)
	if len(rows) != 2 {
		t.Fatal("five-minute sample boundary rejected")
	}
}

type bikeHistoryRecorder struct {
	calls int
	args  []any
	err   error
}

func (r *bikeHistoryRecorder) ExecContext(_ context.Context, query string, args ...any) (sql.Result, error) {
	r.calls++
	if !strings.Contains(query, "INSERT IGNORE INTO bike_availability_history") {
		return nil, errors.New("wrong history target")
	}
	r.args = append([]any(nil), args...)
	return nil, r.err
}

func TestBikeHistoryWriterBindsUTCAndReportsStorageFailure(t *testing.T) {
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, time.FixedZone("Taipei", 8*60*60))
	records := [][]any{{"quality-station", 5, 7, now}}
	recorder := &bikeHistoryRecorder{}
	saveBikeAvailabilityHistory(context.Background(), nil, records)
	saveBikeAvailabilityHistory(context.Background(), recorder, nil)
	if recorder.calls != 0 {
		t.Fatal("empty history touched storage")
	}
	saveBikeAvailabilityHistory(context.Background(), recorder, records)
	if recorder.calls != 1 || len(recorder.args) != 4 || recorder.args[3].(time.Time).Location() != time.UTC || !recorder.args[3].(time.Time).Equal(now) {
		t.Fatalf("bound history=%v", recorder.args)
	}
	core, logs := observer.New(zap.WarnLevel)
	oldLogger := zap.L()
	zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(func() { zap.ReplaceGlobals(oldLogger) })
	recorder.err = errors.New("archive unavailable")
	saveBikeAvailabilityHistory(context.Background(), recorder, records)
	if logs.Len() != 1 || logs.All()[0].ContextMap()["component"] != "bike_history" {
		t.Fatal("history storage failure was not reported")
	}
}
