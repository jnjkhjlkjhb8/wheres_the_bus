package bus

import (
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

// dirs builds a Directions map with n entries so a subroute's direction count
// can be set without caring about the Direction contents.
func dirs(n int) map[int32]*models.Direction {
	m := make(map[int32]*models.Direction, n)
	for i := range n {
		m[int32(i)] = &models.Direction{}
	}
	return m
}

func TestFindConvergenceViolations(t *testing.T) {
	subRoutemap := map[string]*models.BusSubroute{
		"THB9023": {Directions: dirs(2)}, // healthy: two directions
		"THB9099": {Directions: dirs(3)}, // too many directions
		"TPE1234": {Directions: dirs(1)}, // healthy single direction
		"THB8000": {Directions: dirs(2)}, // healthy count, name mismatch below
	}
	nameObs := map[string]map[string]struct{}{
		"THB9023": {"1路": {}},           // single name: ok
		"THB8000": {"甲線": {}, "乙線": {}}, // divergent names
		"TPE1234": {"20路": {}},          // single name: ok
	}

	got := findConvergenceViolations(subRoutemap, nameObs)

	want := []convergenceViolation{
		{canonical: "THB8000", issue: "name_mismatch", detail: "乙線|甲線"},
		{canonical: "THB9099", issue: "too_many_directions", detail: "3"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d violations %+v, want %d", len(got), got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("violation %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestFindConvergenceViolationsClean(t *testing.T) {
	subRoutemap := map[string]*models.BusSubroute{
		"THB9023": {Directions: dirs(2)},
		"TPE1234": {Directions: dirs(1)},
	}
	nameObs := map[string]map[string]struct{}{
		"THB9023": {"1路": {}},
		"TPE1234": {"20路": {}},
	}
	if got := findConvergenceViolations(subRoutemap, nameObs); len(got) != 0 {
		t.Fatalf("expected no violations, got %+v", got)
	}
}
