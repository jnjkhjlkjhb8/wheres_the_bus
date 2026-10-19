package bike

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
)

func TestBikeNativeMalformedSnapshotIsNotPublishedOrAcknowledged(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "off")
	owner := shared.LiveOwnedKeysKey("bike", "Taipei")
	originalKey := shared.BikeAvailabilityKey("owned-last-good")
	sink := &captureLiveSink{owned: map[string][]string{owner: {originalKey}}}
	closeCause := errors.New("owned response close failed")
	closed, acknowledged := false, false
	closeFetch := func() error { closed = true; return closeCause }
	t.Cleanup(func() {
		if !closed {
			_ = closeFetch()
		}
	})
	fetch := func(_ context.Context, _ string, name string) (*shared.TDXFetch, error) {
		if name != "bike_availabilityTaipei" {
			return &shared.TDXFetch{Modified: false}, nil
		}
		return &shared.TDXFetch{
			Modified: true,
			Decoder:  json.NewDecoder(strings.NewReader(`[{"StationUID":"owned-incomplete","AvailableReturnBikes":7},]`)),
			Close:    closeFetch,
			Ack:      func() error { acknowledged = true; return nil },
		}, nil
	}
	err := Eta(context.Background(), fetch, sink, nil)
	var syntaxErr *json.SyntaxError
	if !errors.As(err, &syntaxErr) || !errors.Is(err, closeCause) {
		t.Fatalf("malformed snapshot lost decode or close cause: %v", err)
	}
	if !closed || acknowledged {
		t.Fatalf("failed fetch lifecycle: closed=%v acknowledged=%v", closed, acknowledged)
	}
	if len(sink.contexts) != 0 {
		t.Fatal("malformed snapshot executed its buffered writes")
	}
	if got := sink.owned[owner]; len(got) != 1 || got[0] != originalKey {
		t.Fatalf("malformed city replaced the last-good ownership set: %v", got)
	}
}

func TestBikeNativeCadenceRecoveryRetainsRefreshAndDeleteFailures(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "on")
	refreshCause := errors.New("owned snapshot missing a member")
	deleteCause := errors.New("owned cadence deletion rejected")
	owner := shared.LiveOwnedKeysKey("bike", "Taipei")
	originalKey := shared.BikeAvailabilityKey("owned-stale")
	sink := &captureLiveSink{
		strings:    map[string]string{},
		owned:      map[string][]string{owner: {originalKey}},
		refreshErr: refreshCause,
		execErr:    deleteCause,
	}
	for _, city := range busmodel.Cities {
		sink.strings[shared.LiveColdKey("bike", city)] = "1"
	}
	fetched := false
	fetch := func(context.Context, string, string) (*shared.TDXFetch, error) {
		fetched = true
		return nil, errors.New("unexpected gated fetch")
	}
	err := Eta(context.Background(), fetch, sink, nil)
	if !errors.Is(err, refreshCause) || !errors.Is(err, deleteCause) {
		t.Fatalf("cadence recovery lost an original cause: %v", err)
	}
	if fetched {
		t.Fatal("gated cities fetched TDX despite the cold cadence claims")
	}
	deleted := false
	for _, expiry := range sink.expires {
		if expiry.key == shared.LiveColdKey("bike", "Taipei") && expiry.ttl == 0 {
			deleted = true
		}
	}
	if !deleted {
		t.Fatal("failed ownership refresh did not attempt to drop Taipei cadence claim")
	}
	if got := sink.owned[owner]; len(got) != 1 || got[0] != originalKey {
		t.Fatalf("recovery discarded last-good ownership: %v", got)
	}
}
