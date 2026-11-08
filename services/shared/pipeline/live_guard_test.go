package pipeline

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
)

func steppedGuard() (*LiveFetchGuard, *time.Time) {
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	guard := NewLiveFetchGuard()
	guard.now = func() time.Time { return now }
	return guard, &now
}

func TestLiveFetchGuardSkipsInFlightAndRecentFetches(t *testing.T) {
	guard, now := steppedGuard()
	release, ok := guard.Claim("bus_eta", "Tainan")
	if !ok {
		t.Fatal("first claim refused")
	}
	*now = now.Add(time.Minute)
	if _, ok := guard.Claim("bus_eta", "Tainan"); ok {
		t.Fatal("claim granted while the first fetch is in flight")
	}
	release()
	*now = now.Add(-time.Minute + _liveFetchSpacing - time.Nanosecond)
	if _, ok := guard.Claim("bus_eta", "Tainan"); ok {
		t.Fatal("claim granted inside the spacing")
	}
	if _, ok := guard.Claim("bike", "Tainan"); !ok {
		t.Fatal("another dataset was blocked by bus_eta")
	}
	if _, ok := guard.Claim("bus_eta", "Kaohsiung"); !ok {
		t.Fatal("another city was blocked by Tainan")
	}
	*now = now.Add(time.Nanosecond)
	release, ok = guard.Claim("bus_eta", "Tainan")
	if !ok {
		t.Fatal("claim refused once the spacing had passed")
	}
	release()
}

func TestNilLiveFetchGuardClaimsEverything(t *testing.T) {
	var guard *LiveFetchGuard
	for range 2 {
		release, ok := guard.Claim("tra", "TRA")
		if !ok {
			t.Fatal("nil guard refused a claim")
		}
		release()
	}
}

func TestLiveFetchGuardGrantsOneOfConcurrentClaims(t *testing.T) {
	guard := NewLiveFetchGuard()
	var granted atomic.Int32
	var wg sync.WaitGroup
	for range 16 {
		wg.Go(func() {
			if _, ok := guard.Claim("bike", "Taichung"); ok {
				granted.Add(1)
			}
		})
	}
	wg.Wait()
	if granted.Load() != 1 {
		t.Fatalf("granted %d concurrent claims, want 1", granted.Load())
	}
}

func TestClaimLiveDemandGatesBeforeClaiming(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	ctx := context.Background()
	guard, _ := steppedGuard()
	sink := &demandSink{strings: map[string]string{}, errors: map[string]error{}}
	if _, ok := ClaimLiveDemand(ctx, sink, guard, "tra", "TRA"); ok {
		t.Fatal("claimed a partition without demand")
	}
	// The refused tick must leave no claim, or the wake right after it would be
	// skipped for the whole spacing.
	sink.strings[shared.LiveDemandKey("tra", "TRA")] = "1"
	release, ok := ClaimLiveDemand(ctx, sink, guard, "tra", "TRA")
	if !ok {
		t.Fatal("demand right after a refused tick was not claimed")
	}
	release()
	if _, ok := ClaimLiveDemand(ctx, sink, guard, "tra", "TRA"); ok {
		t.Fatal("a second fetch inside the spacing was claimed")
	}
	if sink.reads != 3 {
		t.Fatalf("demand reads=%d, want 3", sink.reads)
	}
}

// TestLiveFetchSpacingStaysUnderEveryCadence: the spacing must stay shorter
// than the fastest gated cadence (30 s), or a tick would skip the tick before.
func TestLiveFetchSpacingStaysUnderEveryCadence(t *testing.T) {
	if _liveFetchSpacing != 10*time.Second {
		t.Fatalf("spacing=%v, want 10s", _liveFetchSpacing)
	}
}
