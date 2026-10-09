package bike

import (
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
