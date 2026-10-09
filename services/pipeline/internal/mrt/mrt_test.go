package mrt

import (
	"encoding/json"
	"testing"
)

func TestMrtTravelGraph(t *testing.T) {
	// Line BL: BL01 -(110s)- BL02 -(125s)- BL03. Line R: R01 -(100s)- R02.
	// Transfer BL02 <-> R01 = 3 min = 180s. Keys lowercased as landing emits them.
	var lines []mrtS2SRow
	if err := json.Unmarshal([]byte(`[{"traveltimes":[
		{"fromstationid":"BL01","tostationid":"BL02","runtime":90,"stoptime":20},
		{"fromstationid":"BL02","tostationid":"BL03","runtime":100,"stoptime":25},
		{"fromstationid":"R01","tostationid":"R02","runtime":80,"stoptime":20}]}]`), &lines); err != nil {
		t.Fatal(err)
	}
	var transfers []mrtLineTransfer
	if err := json.Unmarshal([]byte(`[{"fromstationid":"BL02","tostationid":"R01","transfertime":3}]`), &transfers); err != nil {
		t.Fatal(err)
	}

	stations, dist, segs, xfers, err := mrtTravelGraph(lines, transfers)
	if err != nil {
		t.Fatalf("mrtTravelGraph: %v", err)
	}
	if segs != 3 || xfers != 1 {
		t.Fatalf("edge counts: segs=%d xfers=%d, want 3/1", segs, xfers)
	}
	pos := map[string]int{}
	for i, s := range stations {
		pos[s] = i
	}
	sec := func(a, b string) int64 { return dist[pos[a]][pos[b]] }

	cases := []struct {
		from, to         string
		wantSec, wantMin int64
	}{
		{"BL01", "BL03", 235, 4}, // 110 + 125
		{"BL01", "R02", 390, 7},  // 110 + 180 (transfer) + 100
		{"R02", "BL01", 390, 7},  // undirected
	}
	for _, c := range cases {
		if got := sec(c.from, c.to); got != c.wantSec {
			t.Errorf("%s->%s seconds = %d, want %d", c.from, c.to, got, c.wantSec)
		} else if mins := max((got+30)/60, 1); mins != c.wantMin {
			t.Errorf("%s->%s minutes = %d, want %d", c.from, c.to, mins, c.wantMin)
		}
	}
}

func TestMrtODFareFares(t *testing.T) {
	var f mrtODFare
	if err := json.Unmarshal([]byte(`{"OriginStationID":"BL01","DestinationStationID":"BL05","Fares":[
		{"TicketType":1,"FareClass":1,"Price":25},
		{"TicketType":1,"FareClass":2,"Price":12},
		{"TicketType":1,"FareClass":4,"Price":10},
		{"TicketType":3,"FareClass":1,"Price":20}]}`), &f); err != nil {
		t.Fatal(err)
	}
	if full, half := f.fares(); full != 25 || half != 12 {
		t.Errorf("fares() = (%d,%d), want (25,12)", full, half)
	}

	var noHalf mrtODFare
	if err := json.Unmarshal([]byte(`{"Fares":[{"TicketType":1,"FareClass":1,"Price":25}]}`), &noHalf); err != nil {
		t.Fatal(err)
	}
	if full, half := noHalf.fares(); full != 25 || half != 0 {
		t.Errorf("fares() without a half fare = (%d,%d), want (25,0)", full, half)
	}
}

// TestParseHHMM covers the text time shapes mrt_schedule actually stores,
// including past-midnight hours ("24:40") and malformed values.

// TestMrtInService verifies the out-of-service filter: in-window and grace-band
// entries pass, post-close entries are dropped, cross-midnight last trains keep
// matching after 00:00, and keys without schedule rows fail open.

// 06:00 first, 00:40 last (crosses midnight → stored as 1480).

func TestMrtAdjacencyRows(t *testing.T) {
	lines := []AdjacencyRow{
		{LineID: "BL", TravelTimes: []struct {
			FromStationID string `json:"FromStationID"`
			ToStationID   string `json:"ToStationID"`
		}{
			{FromStationID: "BL12", ToStationID: "BL13"},
			{FromStationID: "BL13", ToStationID: "BL14"},
		}},
	}
	rows := AdjacencyRows(lines, "TRTC")
	// Two segments, both directions each = four directed edges.
	if len(rows) != 4 {
		t.Fatalf("rows = %d want 4", len(rows))
	}
	seen := map[string]bool{}
	for _, r := range rows {
		if r[0] != "TRTC" || r[1] != "BL" {
			t.Errorf("row system/line = %v/%v", r[0], r[1])
		}
		seen[r[2].(string)+"->"+r[3].(string)] = true
	}
	for _, want := range []string{"BL12->BL13", "BL13->BL12", "BL13->BL14", "BL14->BL13"} {
		if !seen[want] {
			t.Errorf("missing directed edge %s", want)
		}
	}
}
