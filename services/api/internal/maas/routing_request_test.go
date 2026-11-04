package maas

import "testing"

func TestConvertSectionPreservesOptionalAgencyAndTransport(t *testing.T) {
	source := tdxSection{Type: "transit", Transport: tdxTransport{Mode: "BUS", Name: "307", Headsign: "往市區", Category: "市區公車", RouteColor: "#123456"}, Agency: tdxAgency{AgencyID: "operator", Name: "業者", Website: "https://example.test", Phone: "123"}, IntermediateStops: []tdxStop{{Departure: tdxPlaceInfo{Time: "12:40", Place: tdxPlace{Name: "中途站", Location: tdxLocation{Lat: 25, Lng: 121}}}}}}
	got := convertSection(source)
	if got.Transport == nil || got.Transport.Mode != "BUS" || got.Transport.Name != "307" || got.Transport.Headsign != "往市區" || got.Transport.Category != "市區公車" || got.Transport.RouteColor != "#123456" {
		t.Fatalf("transport = %v", got.Transport)
	}
	if got.Agency == nil || got.Agency.AgencyId != "operator" || got.Agency.Name != "業者" || got.Agency.Website != "https://example.test" || got.Agency.Phone != "123" {
		t.Fatalf("agency = %v", got.Agency)
	}
	if len(got.IntermediateStops) != 1 || got.IntermediateStops[0].Name != "中途站" || got.IntermediateStops[0].DepartureTime != "12:40" || got.IntermediateStops[0].Location.Lat != 25 || got.IntermediateStops[0].Location.Lng != 121 {
		t.Fatalf("intermediate stops = %v", got.IntermediateStops)
	}
	empty := convertSection(tdxSection{})
	if empty.Transport != nil || empty.Agency != nil || len(empty.IntermediateStops) != 0 {
		t.Fatalf("empty optional details = %v", empty)
	}
}

func TestWalkInstructionsHandleNamedAndUnnamedManeuvers(t *testing.T) {
	for _, tc := range []struct{ modifier, want string }{
		{"left", "左轉"}, {"right", "右轉"}, {"slight left", "稍向左"}, {"slight right", "稍向右"},
		{"sharp left", "向左急轉"}, {"sharp right", "向右急轉"}, {"uturn", "迴轉"},
	} {
		if got := walkInstruction("turn", tc.modifier, ""); got != tc.want {
			t.Errorf("unnamed %s = %q", tc.modifier, got)
		}
		if got := walkInstruction("turn", tc.modifier, "道路"); got != tc.want+"進入道路" {
			t.Errorf("named %s = %q", tc.modifier, got)
		}
	}
	for _, tc := range []struct{ maneuver, name, want string }{
		{"depart", "", "開始步行"}, {"depart", "道路", "沿道路出發"}, {"arrive", "ignored", "抵達目的地"},
		{"continue", "道路", "沿道路直走"}, {"continue", "", "繼續直走"},
	} {
		if got := walkInstruction(tc.maneuver, "", tc.name); got != tc.want {
			t.Errorf("%s/%s = %q, want %q", tc.maneuver, tc.name, got, tc.want)
		}
	}
}
