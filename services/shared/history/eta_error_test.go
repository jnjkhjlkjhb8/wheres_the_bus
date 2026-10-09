package history

import (
	"testing"
	"time"
)

func TestMatchPredictionActual(t *testing.T) {
	base := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)
	window := 30 * time.Minute

	preds := []PredictionRecord{
		// Matches the arrival 5 min later.
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1", Source: SourceModel, PredictedAt: base, PredictedSecs: 240},
		// No arrival at this stop => dropped.
		{SubRouteUID: "R1", Direction: 0, StopUID: "S9", Source: SourceTDX, PredictedAt: base, PredictedSecs: 100},
		// Arrival exists but before predictedAt => dropped.
		{SubRouteUID: "R2", Direction: 1, StopUID: "S2", Source: SourcePropagation, PredictedAt: base.Add(20 * time.Minute), PredictedSecs: 60},
		// Arrival exists but beyond the window => dropped.
		{SubRouteUID: "R3", Direction: 0, StopUID: "S3", Source: SourceSchedule, PredictedAt: base, PredictedSecs: 60},
	}
	arrivals := []arrivalEvent{
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1", arrivedAt: base.Add(5 * time.Minute)},
		{SubRouteUID: "R2", Direction: 1, StopUID: "S2", arrivedAt: base.Add(10 * time.Minute)}, // before pred-at of R2 pred
		{SubRouteUID: "R3", Direction: 0, StopUID: "S3", arrivedAt: base.Add(45 * time.Minute)}, // beyond window
	}

	got := matchPredictionActual(preds, arrivals, window)
	if len(got) != 1 {
		t.Fatalf("matched %d, want 1: %+v", len(got), got)
	}
	m := got[0]
	if m.SubRouteUID != "R1" || m.StopUID != "S1" || m.Source != SourceModel {
		t.Fatalf("unexpected match: %+v", m)
	}
	if m.PredictedSecs != 240 {
		t.Fatalf("predictedSecs = %d, want 240", m.PredictedSecs)
	}
	if m.actualSecs != 300 {
		t.Fatalf("actualSecs = %d, want 300", m.actualSecs)
	}
}

func TestMatchPredictionActual_PicksEarliestArrival(t *testing.T) {
	base := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)
	preds := []PredictionRecord{
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1", Source: SourceTDX, PredictedAt: base, PredictedSecs: 120},
	}
	// Two arrivals after the prediction; the earlier one is the actual.
	arrivals := []arrivalEvent{
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1", arrivedAt: base.Add(8 * time.Minute)},
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1", arrivedAt: base.Add(3 * time.Minute)},
	}
	got := matchPredictionActual(preds, arrivals, 30*time.Minute)
	if len(got) != 1 {
		t.Fatalf("matched %d, want 1", len(got))
	}
	if got[0].actualSecs != 180 {
		t.Fatalf("actualSecs = %d, want 180 (earliest arrival)", got[0].actualSecs)
	}
}

func TestAggregateMAE(t *testing.T) {
	errs := []matchedError{
		// R1/model: |100-120|=20, |200-160|=40 => MAE 30 over 2.
		{SubRouteUID: "R1", Source: SourceModel, PredictedSecs: 100, actualSecs: 120},
		{SubRouteUID: "R1", Source: SourceModel, PredictedSecs: 200, actualSecs: 160},
		// R1/propagation: |50-60|=10 => MAE 10 over 1.
		{SubRouteUID: "R1", Source: SourcePropagation, PredictedSecs: 50, actualSecs: 60},
		// R2/tdx: |300-300|=0 => MAE 0 over 1.
		{SubRouteUID: "R2", Source: SourceTDX, PredictedSecs: 300, actualSecs: 300},
	}
	got := aggregateMAE(errs)
	if len(got) != 3 {
		t.Fatalf("groups = %d, want 3: %+v", len(got), got)
	}
	// Sorted by route then source.
	want := []maeStat{
		{SubRouteUID: "R1", Source: SourceModel, maeSeconds: 30, samples: 2},
		{SubRouteUID: "R1", Source: SourcePropagation, maeSeconds: 10, samples: 1},
		{SubRouteUID: "R2", Source: SourceTDX, maeSeconds: 0, samples: 1},
	}
	for i, w := range want {
		g := got[i]
		if g.SubRouteUID != w.SubRouteUID || g.Source != w.Source || g.samples != w.samples || g.maeSeconds != w.maeSeconds {
			t.Fatalf("group %d = %+v, want %+v", i, g, w)
		}
	}
}

func TestAggregateMAE_Empty(t *testing.T) {
	if got := aggregateMAE(nil); len(got) != 0 {
		t.Fatalf("want empty, got %+v", got)
	}
}
