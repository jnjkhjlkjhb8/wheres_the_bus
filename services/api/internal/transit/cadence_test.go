package transit

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestNearCadenceWaitsOnlyForRecentQueries(t *testing.T) {
	for _, last := range []time.Time{{}, time.Now().Add(-time.Second)} {
		if err := waitNearCadence(t.Context(), last); err != nil {
			t.Fatalf("first or old query error = %v", err)
		}
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := waitNearCadence(ctx, time.Now()); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled cadence error = %v", err)
	}
	started := time.Now()
	if err := waitNearCadence(t.Context(), started.Add(-60*time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed < 20*time.Millisecond {
		t.Fatalf("recent query bypassed cadence: elapsed %v", elapsed)
	}
}
