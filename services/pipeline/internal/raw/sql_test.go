package raw

import (
	"strings"
	"testing"
)

func TestRawDeleteSQL(t *testing.T) {
	got := rawDeleteSQL(Target{Table: "bus_route", PartCol: "city"})
	want := "DELETE FROM raw_tdx.bus_route WHERE city = $1"
	if got != want {
		t.Errorf("rawDeleteSQL = %q, want %q", got, want)
	}
}

func TestRawInsertSQLStructure(t *testing.T) {
	got := rawInsertSQL("metro_station")
	for _, sub := range []string{
		"INSERT INTO raw_tdx.metro_station",
		"NULL::raw_tdx.metro_station",
		"jsonb_array_elements($2::jsonb)",
		"jsonb_object_agg(lower(",
		"$1::jsonb",
	} {
		if !strings.Contains(got, sub) {
			t.Errorf("rawInsertSQL missing %q in:\n%s", sub, got)
		}
	}
}
