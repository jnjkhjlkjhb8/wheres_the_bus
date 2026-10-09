package pipeline

import (
	"fmt"
	"strings"
	"testing"
)

// The legacy log parser splits a formatted line into key=value attrs, so a
// detail carrying spaces or '=' (wrapped error text, mostly) was shredded into
// bogus fields and truncated at the first space.
func TestLoadQuarantineDetailSurvivesLogParser(t *testing.T) {
	q := NewQuarantine("bus", "Tainan")
	q.Drop("subroute", "subroute_identity", `Route[15].SubRoutes[0] uid="TNN104500" dir=2`)
	q.Drop("subroute", "subroute_identity", "second sample is ignored")
	got := q.sample["subroute_identity"]
	if strings.ContainsAny(got, " =\"") {
		t.Fatalf("sample = %q, want no space, '=' or quote to survive the log parser", got)
	}
	if !strings.Contains(got, "TNN104500") {
		t.Fatalf("sample = %q, want the offending record still identifiable", got)
	}
	if q.dropped["subroute_identity"] != 2 {
		t.Fatalf("count = %d, want both drops counted", q.dropped["subroute_identity"])
	}
}

// The gate exists because the 2026-07-17 run dropped 223 of Taipei's shapes as
// a "tail". A tail is a handful of records; a third of a city's shapes is a
// defect, and quarantining it silently ships a gutted city that looks fresh.
func TestLoadQuarantineRatioGate(t *testing.T) {
	tests := []struct {
		name    string
		seen    int
		drops   int
		wantErr bool
	}{
		{"clean", 400, 0, false},
		{"tail stays under the limit", 400, 13, false},
		{"exactly at the limit passes", 400, 40, false},
		{"a third of the city fails", 400, 223, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			q := NewQuarantine("bus", "Taipei")
			q.Consider("shape", tt.seen)
			for i := range tt.drops {
				q.Drop("shape", "shape_unknown_direction", fmt.Sprintf("Shape[%d]", i))
			}
			err := q.Exceeded()
			if tt.wantErr && err == nil {
				t.Fatalf("exceeded() = nil, want a ratio error for %d/%d", tt.drops, tt.seen)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("exceeded() = %v, want nil for %d/%d", err, tt.drops, tt.seen)
			}
		})
	}
}

// A kind that dropped nothing must not gate on a zero denominator, and one
// kind blowing its limit must not be masked by another kind being clean.
func TestLoadQuarantineRatioGateIsPerKind(t *testing.T) {
	q := NewQuarantine("bus", "Taipei")
	q.Consider("shape", 400)
	q.Consider("subroute", 4000)
	for i := range 223 {
		q.Drop("shape", "shape_unknown_direction", fmt.Sprintf("Shape[%d]", i))
	}
	err := q.Exceeded()
	if err == nil {
		t.Fatal("exceeded() = nil, want the shape ratio to fail despite 4000 clean subroutes")
	}
	if !errMentions(err, "shape") {
		t.Fatalf("exceeded() = %v, want the offending kind named", err)
	}
	// No drops at all: nothing to gate on, including kinds never considered.
	if err := NewQuarantine("bus", "Taipei").Exceeded(); err != nil {
		t.Fatalf("exceeded() = %v, want nil for a clean partition", err)
	}
}

func TestQuarantineRatioLimitEnvOverride(t *testing.T) {
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "0.5")
	if got := QuarantineRatioLimit(); got != 0.5 {
		t.Fatalf("QuarantineRatioLimit() = %v, want 0.5", got)
	}
	// A nonsense value must not silently disable the gate.
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "banana")
	if got := QuarantineRatioLimit(); got != _defaultQuarantineRatio {
		t.Fatalf("QuarantineRatioLimit() = %v, want the %v default", got, _defaultQuarantineRatio)
	}
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "7")
	if got := QuarantineRatioLimit(); got != _defaultQuarantineRatio {
		t.Fatalf("QuarantineRatioLimit() = %v, want the %v default for an out-of-range value", got, _defaultQuarantineRatio)
	}
}
