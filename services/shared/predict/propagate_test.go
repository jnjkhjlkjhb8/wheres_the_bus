package predict

import (
	"math"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestDecayDelay(t *testing.T) {
	tests := []struct {
		name   string
		delay  float64
		seqGap int
		want   float64
	}{
		{name: "zero gap unchanged", delay: 100, seqGap: 0, want: 100},
		{name: "negative gap unchanged", delay: 100, seqGap: -2, want: 100},
		{name: "one stop", delay: 100, seqGap: 1, want: 90},
		{name: "two stops", delay: 100, seqGap: 2, want: 81},
		{name: "three stops", delay: 100, seqGap: 3, want: 72.9},
		{name: "negative delay decays too", delay: -50, seqGap: 2, want: -40.5},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := decayDelay(tt.delay, tt.seqGap)
			if math.Abs(got-tt.want) > 1e-6 {
				t.Fatalf("decayDelay(%v, %d) = %v, want %v", tt.delay, tt.seqGap, got, tt.want)
			}
		})
	}
}

func TestLatestUpstreamDelay(t *testing.T) {
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, pipeline.Taipei)
	fresh := now.Add(-1 * time.Minute)
	stale := now.Add(-5 * time.Minute)

	tests := []struct {
		name      string
		obs       []UpstreamObs
		targetSeq int
		wantOK    bool
		wantSeq   int
		wantDelay float64
	}{
		{
			name:      "no observations",
			obs:       nil,
			targetSeq: 5,
			wantOK:    false,
		},
		{
			name: "picks closest upstream",
			obs: []UpstreamObs{
				{StopSequence: 1, DelaySeconds: 30, ObservedAt: fresh},
				{StopSequence: 3, DelaySeconds: 60, ObservedAt: fresh},
				{StopSequence: 2, DelaySeconds: 45, ObservedAt: fresh},
			},
			targetSeq: 5,
			wantOK:    true,
			wantSeq:   3,
			wantDelay: 60,
		},
		{
			name: "ignores observation at target",
			obs: []UpstreamObs{
				{StopSequence: 5, DelaySeconds: 99, ObservedAt: fresh},
				{StopSequence: 2, DelaySeconds: 45, ObservedAt: fresh},
			},
			targetSeq: 5,
			wantOK:    true,
			wantSeq:   2,
			wantDelay: 45,
		},
		{
			name: "ignores observation past target",
			obs: []UpstreamObs{
				{StopSequence: 7, DelaySeconds: 99, ObservedAt: fresh},
			},
			targetSeq: 5,
			wantOK:    false,
		},
		{
			name: "skips stale, keeps fresh",
			obs: []UpstreamObs{
				{StopSequence: 4, DelaySeconds: 99, ObservedAt: stale},
				{StopSequence: 1, DelaySeconds: 20, ObservedAt: fresh},
			},
			targetSeq: 5,
			wantOK:    true,
			wantSeq:   1,
			wantDelay: 20,
		},
		{
			name: "all stale yields nothing",
			obs: []UpstreamObs{
				{StopSequence: 4, DelaySeconds: 99, ObservedAt: stale},
			},
			targetSeq: 5,
			wantOK:    false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			delay, seq, ok := latestUpstreamDelay(tt.obs, tt.targetSeq, now)
			if ok != tt.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOK)
			}
			if !tt.wantOK {
				return
			}
			if seq != tt.wantSeq {
				t.Fatalf("seq = %d, want %d", seq, tt.wantSeq)
			}
			if delay != tt.wantDelay {
				t.Fatalf("delay = %v, want %v", delay, tt.wantDelay)
			}
		})
	}
}

func TestPropagateDelay(t *testing.T) {
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, pipeline.Taipei)
	baseline := now.Add(10 * time.Minute) // downstream schedule+avg arrival

	t.Run("zero baseline returns not ok", func(t *testing.T) {
		_, ok := PropagateDelay(time.Time{}, 5, []UpstreamObs{
			{StopSequence: 1, DelaySeconds: 60, ObservedAt: now},
		}, now)
		if ok {
			t.Fatal("want not ok for zero baseline")
		}
	})

	t.Run("no upstream returns not ok", func(t *testing.T) {
		_, ok := PropagateDelay(baseline, 5, nil, now)
		if ok {
			t.Fatal("want not ok with no observations")
		}
	})

	t.Run("adds decayed delay to baseline", func(t *testing.T) {
		// Observed at seq 2, target seq 5 => gap 3 => 90s * 0.9^3 = 65.61s.
		got, ok := PropagateDelay(baseline, 5, []UpstreamObs{
			{StopSequence: 2, DelaySeconds: 90, ObservedAt: now},
		}, now)
		if !ok {
			t.Fatal("want ok")
		}
		// decay is a variable, not a constant: the conversion below has to
		// truncate 65.61 the way the production code does, and a constant
		// expression would refuse to convert at all.
		decay := 0.9
		wantOffset := time.Duration(90*decay*decay*decay) * time.Second
		want := baseline.Add(wantOffset)
		if got.Unix() != want.Unix() {
			t.Fatalf("got %v, want %v", got, want)
		}
	})

	t.Run("negative delay pulls arrival earlier", func(t *testing.T) {
		got, ok := PropagateDelay(baseline, 3, []UpstreamObs{
			{StopSequence: 2, DelaySeconds: -60, ObservedAt: now},
		}, now)
		if !ok {
			t.Fatal("want ok")
		}
		if !got.Before(baseline) {
			t.Fatalf("expected arrival before baseline, got %v (baseline %v)", got, baseline)
		}
	})
}
