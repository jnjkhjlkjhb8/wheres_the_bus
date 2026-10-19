package livestream

import (
	"context"
	"testing"
	"time"
)

type leasedDemandSource struct {
	*fakeLiveSource
	leases []time.Duration
}

func (s *leasedDemandSource) Touch(ctx context.Context, key string, ttl time.Duration) {
	s.leases = append(s.leases, ttl)
	s.fakeLiveSource.Touch(ctx, key, ttl)
}

func TestDemandClaimAndRenewalKeepTenMinuteLease(t *testing.T) {
	src := &leasedDemandSource{fakeLiveSource: newFakeLiveSource()}
	stream := newLiveStream(t.Context(), src, LiveStreamSpec{DemandKey: "live:demand:bus_eta:Taipei"}, func([]byte) error { return nil })
	stream.refreshDemand(t.Context(), stream.touched.Add(4*time.Minute))
	if len(src.leases) != 2 {
		t.Fatalf("demand leases = %v, want initial claim and renewal", src.leases)
	}
	for _, ttl := range src.leases {
		if ttl != 10*time.Minute {
			t.Fatalf("demand TTL = %v, want ten minutes", ttl)
		}
	}
}

func TestDemandRefreshUsesFourMinuteIntervals(t *testing.T) {
	src := newFakeLiveSource()
	start := time.Unix(1_800_000_000, 0)
	stream := liveStream{source: src, spec: LiveStreamSpec{DemandKey: "live:demand:bus_eta:Taipei"}, touched: start}
	for _, tt := range []struct {
		elapsed time.Duration
		touches int
	}{
		{4*time.Minute - time.Nanosecond, 0},
		{4 * time.Minute, 1},
		{8*time.Minute - time.Nanosecond, 1},
		{8 * time.Minute, 2},
	} {
		stream.refreshDemand(t.Context(), start.Add(tt.elapsed))
		if len(src.touches) != tt.touches {
			t.Fatalf("touches after %v = %v, want %d", tt.elapsed, src.touches, tt.touches)
		}
	}
}
