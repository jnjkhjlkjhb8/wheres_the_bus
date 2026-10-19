package main

import (
	"reflect"
	"testing"
)

func TestRawIngestSelectionPreservesScopeAndSelectedDatasets(t *testing.T) {
	cases := []struct {
		name   string
		tables []string
		scope  string
		only   map[string]bool
	}{
		{name: "nil means all", scope: "all", only: map[string]bool{}},
		{name: "empty means all", tables: []string{}, scope: "all", only: map[string]bool{}},
		{name: "one dataset", tables: []string{"bus_route"}, scope: "bus_route", only: map[string]bool{"bus_route": true}},
		{name: "caller order", tables: []string{"bike", "bus_route"}, scope: "bike,bus_route", only: map[string]bool{"bike": true, "bus_route": true}},
		{name: "repeated selection", tables: []string{"bike", "bus_route", "bike"}, scope: "bike,bus_route,bike", only: map[string]bool{"bike": true, "bus_route": true}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			scope, only := rawIngestSelection(tc.tables)
			if scope != tc.scope || !reflect.DeepEqual(only, tc.only) {
				t.Fatalf("ingest selection = %q, %v, want %q, %v", scope, only, tc.scope, tc.only)
			}
		})
	}
}
