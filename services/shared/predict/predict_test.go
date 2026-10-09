package predict

import (
	"testing"
	"time"

	"github.com/dmitryikh/leaves"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestDedupRouteDirPairs(t *testing.T) {
	in := []RouteDirKey{
		{"TPE1", 0},
		{"TPE1", 0},
		{"TPE1", 1},
		{"TPE2", 0},
	}
	got := DedupRouteDirPairs(in)
	if len(got) != 3 {
		t.Fatalf("DedupRouteDirPairs len = %d, want 3", len(got))
	}
	seen := map[RouteDirKey]bool{}
	for _, k := range got {
		if seen[k] {
			t.Fatalf("duplicate key in output: %+v", k)
		}
		seen[k] = true
	}
}

func TestPredictNextBusTime_NoModelReturnsEmpty(t *testing.T) {
	p := &predictor{}

	got := p.NextBusTime(nil, StopCtx{}, Inputs{NextDep: time.Now()})
	if got != "" {
		t.Fatalf("want empty, got %q", got)
	}
}

func TestPredictNextBusTime_NoDepartureReturnsEmpty(t *testing.T) {
	p := &predictor{model: &leaves.Ensemble{}}

	got := p.NextBusTime(nil, StopCtx{}, Inputs{})
	if got != "" {
		t.Fatalf("want empty, got %q", got)
	}
}

func TestPredictNextBusTime_NoStopOffsetReturnsDeparture(t *testing.T) {
	p := &predictor{model: &leaves.Ensemble{}}

	now := time.Date(2026, 7, 3, 8, 0, 0, 0, pipeline.Taipei)
	dep := time.Date(2026, 1, 1, 9, 30, 0, 0, pipeline.Taipei)
	got := p.NextBusTime(nil, StopCtx{}, Inputs{
		Now:     now,
		NextDep: dep,
	})
	want := time.Date(2026, 7, 3, 9, 30, 0, 0, pipeline.Taipei).Format(time.RFC3339)
	if got != want {
		t.Fatalf("want %q, got %q", want, got)
	}
}

func TestBaselineArrival(t *testing.T) {
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, pipeline.Taipei)
	dep := time.Date(2026, 1, 1, 8, 5, 0, 0, pipeline.Taipei)

	t.Run("no departure yields zero time", func(t *testing.T) {
		if got := BaselineArrival(Inputs{Now: now}); !got.IsZero() {
			t.Fatalf("want zero time, got %v", got)
		}
	})

	t.Run("departure plus stop offset", func(t *testing.T) {
		got := BaselineArrival(Inputs{
			Now: now, NextDep: dep, OffsetSec: 120, HasOffset: true,
		})
		want := time.Date(2026, 7, 6, 8, 7, 0, 0, pipeline.Taipei)
		if !got.Equal(want) {
			t.Fatalf("got %v, want %v", got, want)
		}
	})

	t.Run("no stop offset yields bare departure", func(t *testing.T) {
		got := BaselineArrival(Inputs{Now: now, NextDep: dep})
		want := time.Date(2026, 7, 6, 8, 5, 0, 0, pipeline.Taipei)
		if !got.Equal(want) {
			t.Fatalf("got %v, want %v", got, want)
		}
	})
}

func TestBoolToFloat64(t *testing.T) {
	if got := boolToFloat64(true); got != 1 {
		t.Fatalf("true = %v, want 1", got)
	}
	if got := boolToFloat64(false); got != 0 {
		t.Fatalf("false = %v, want 0", got)
	}
}
