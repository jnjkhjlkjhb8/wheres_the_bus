package maas

import (
	"context"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

// TestRailShapeMode pins the MaaS mode string -> rail_shapes.mode mapping.
// Buses (and anything unrecognized) must map to "" so enrichTransitPaths
// skips them: transit-path enrichment is rail/metro only.
func TestRailShapeMode(t *testing.T) {
	tests := []struct {
		mode string
		want string
	}{
		{"subway", "metro"},
		{"METRO", "metro"},
		{"mrt", "metro"},
		{"thsr", "thsr"},
		{"HSR", "thsr"},
		{"rail", "tra"},
		{"TRA", "tra"},
		{"train", "tra"},
		{"bus", ""},
		{"HighwayBus", ""},
		{"pedestrian", ""},
		{"", ""},
	}
	for _, tt := range tests {
		if got := railShapeMode(tt.mode); got != tt.want {
			t.Errorf("railShapeMode(%q) = %q, want %q", tt.mode, got, tt.want)
		}
	}
}

// TestSectionStopPoints proves the ordered stop assembly a section's
// transitPath is clipped along: departure, every intermediate stop in order,
// then arrival.
func TestSectionStopPoints(t *testing.T) {
	sec := tdxSection{}
	sec.Departure.Place.Location = tdxLocation{Lat: 1, Lng: 1}
	sec.Arrival.Place.Location = tdxLocation{Lat: 4, Lng: 4}
	sec.IntermediateStops = []tdxStop{
		{Departure: tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 2, Lng: 2}}}},
		{Departure: tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 3, Lng: 3}}}},
	}
	got := sectionStopPoints(sec)
	want := []transitStopPoint{{1, 1}, {2, 2}, {3, 3}, {4, 4}}
	if len(got) != len(want) {
		t.Fatalf("sectionStopPoints returned %d points, want %d", len(got), len(want))
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("point %d = %+v, want %+v", i, got[i], w)
		}
	}
}

// TestSectionStopPointsNoIntermediates covers the common two-stop section
// (no IntermediateStops payload at all).
func TestSectionStopPointsNoIntermediates(t *testing.T) {
	sec := tdxSection{}
	sec.Departure.Place.Location = tdxLocation{Lat: 1, Lng: 1}
	sec.Arrival.Place.Location = tdxLocation{Lat: 2, Lng: 2}
	got := sectionStopPoints(sec)
	want := []transitStopPoint{{1, 1}, {2, 2}}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("sectionStopPoints = %+v, want %+v", got, want)
	}
}

// TestAppendTransitSegmentDedupesJointPoint proves the joint point shared by
// two consecutive stop-pair clips is not duplicated in the assembled path.
func TestAppendTransitSegmentDedupesJointPoint(t *testing.T) {
	path := []*pb.Location{{Lat: 1, Lng: 1}, {Lat: 2, Lng: 2}}
	seg := []*pb.Location{{Lat: 2, Lng: 2}, {Lat: 3, Lng: 3}}
	got := appendTransitSegment(path, seg)
	want := []*pb.Location{{Lat: 1, Lng: 1}, {Lat: 2, Lng: 2}, {Lat: 3, Lng: 3}}
	if len(got) != len(want) {
		t.Fatalf("appendTransitSegment len = %d, want %d", len(got), len(want))
	}
	for i, w := range want {
		if got[i].Lat != w.Lat || got[i].Lng != w.Lng {
			t.Errorf("point %d = %+v, want %+v", i, got[i], w)
		}
	}
}

// TestAppendTransitSegmentEmptyPath proves the first segment appends whole
// (no predecessor to dedupe against).
func TestAppendTransitSegmentEmptyPath(t *testing.T) {
	seg := []*pb.Location{{Lat: 1, Lng: 1}, {Lat: 2, Lng: 2}}
	got := appendTransitSegment(nil, seg)
	if len(got) != 2 {
		t.Fatalf("appendTransitSegment(nil, seg) len = %d, want 2", len(got))
	}
}

func TestAppendTransitSegmentNoDedupeWhenDisjoint(t *testing.T) {
	path := []*pb.Location{{Lat: 1, Lng: 1}, {Lat: 2, Lng: 2}}
	seg := []*pb.Location{{Lat: 9, Lng: 9}, {Lat: 3, Lng: 3}}
	got := appendTransitSegment(path, seg)
	if len(got) != 4 {
		t.Fatalf("appendTransitSegment len = %d, want 4 (no dedupe)", len(got))
	}
}

// TestParseWKTLineString proves the ST_AsText(LINESTRING(...)) result is
// parsed into Locations in TDX's [lat,lng] convention from WKT's [lng,lat]
// ordering.
func TestParseWKTLineString(t *testing.T) {
	pts, err := parseWKTLineString("LINESTRING(121.5 25.0,121.6 25.1,121.7 25.2)")
	if err != nil {
		t.Fatalf("parseWKTLineString error: %v", err)
	}
	if len(pts) != 3 {
		t.Fatalf("parseWKTLineString returned %d points, want 3", len(pts))
	}
	if pts[0].Lng != 121.5 || pts[0].Lat != 25.0 {
		t.Errorf("point 0 = %+v, want lng=121.5 lat=25.0", pts[0])
	}
	if pts[2].Lng != 121.7 || pts[2].Lat != 25.2 {
		t.Errorf("point 2 = %+v, want lng=121.7 lat=25.2", pts[2])
	}
}

func TestParseWKTLineStringRejectsNonLineString(t *testing.T) {
	for _, wkt := range []string{
		"MULTILINESTRING((121.5 25.0,121.6 25.1))",
		"POINT(121.5 25.0)",
		"",
		"LINESTRING()",
	} {
		if _, err := parseWKTLineString(wkt); err == nil {
			t.Errorf("parseWKTLineString(%q) should have failed", wkt)
		}
	}
}

func TestClipRailShapeFallsBackWithoutCoordinates(t *testing.T) {
	if _, ok := clipRailShape(context.Background(), nil, "metro", transitStopPoint{1, 1}, transitStopPoint{2, 2}); ok {
		t.Fatal("clipRailShape should report ok=false for a nil db")
	}
}
