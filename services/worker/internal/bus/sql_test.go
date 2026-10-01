package bus

import (
	"strings"
	"testing"
)

func TestBusSubroutesUpsertDeduplicatesConflictKeys(t *testing.T) {
	if !strings.Contains(_busSubroutesUpsertSQL, "SELECT DISTINCT ON (uid, d)") {
		t.Fatalf("bus_subroutes upsert SQL missing DISTINCT ON dedup")
	}
}

func TestBusScheduleInsertKeepsDuplicates(t *testing.T) {
	for _, banned := range []string{"DISTINCT ON", "ON CONFLICT"} {
		if strings.Contains(_busScheduleInsertSQL, banned) {
			t.Fatalf("bus_schedule insert SQL must not contain %q (partition-replace keeps duplicate rows)", banned)
		}
	}
}
