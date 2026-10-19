package maas

import (
	"net/http"
	"testing"

	"github.com/go-resty/resty/v2"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

func TestTDXRoutingRequestClampsLimitsAndDefaultsUnsetPreferences(t *testing.T) {
	for _, tc := range []struct {
		name    string
		request *pb.MaasPlanRequest
		want    map[string]string
	}{
		{"defaults", &pb.MaasPlanRequest{Gc: -0.1}, map[string]string{"gc": "0.0", "top": "5", "transit": "3,4,5,6,7,8,9", "transfer_time": "0,0", "first_mile_mode": "0", "first_mile_time": "10", "last_mile_mode": "0", "last_mile_time": "10"}},
		{"upper limits", &pb.MaasPlanRequest{Gc: 1, Top: 10, TransitModes: []int32{3, 8}, TransferTimeMin: 60, TransferTimeMax: 60, FirstMileMode: 3, FirstMileTime: 60, LastMileMode: 3, LastMileTime: 60}, map[string]string{"gc": "1.0", "top": "10", "transit": "3,8", "transfer_time": "60,60", "first_mile_mode": "3", "first_mile_time": "60", "last_mile_mode": "3", "last_mile_time": "60"}},
		{"lower limits", &pb.MaasPlanRequest{Gc: 0, Top: 1, TransitModes: []int32{9}, FirstMileTime: 1, LastMileTime: 1}, map[string]string{"gc": "0.0", "top": "1", "transit": "9", "transfer_time": "0,0", "first_mile_mode": "0", "first_mile_time": "1", "last_mile_mode": "0", "last_mile_time": "1"}},
		{"invalid high", &pb.MaasPlanRequest{Gc: 1.1, Top: 11, TransferTimeMin: 61, TransferTimeMax: 61, FirstMileMode: 4, FirstMileTime: 61, LastMileMode: 4, LastMileTime: 61}, map[string]string{"gc": "0.0", "top": "10", "transfer_time": "60,60", "first_mile_mode": "3", "first_mile_time": "60", "last_mile_mode": "3", "last_mile_time": "60"}},
		{"invalid low", &pb.MaasPlanRequest{Top: -1, TransferTimeMin: -1, TransferTimeMax: -1, FirstMileMode: -1, FirstMileTime: -1, LastMileMode: -1, LastMileTime: -1}, map[string]string{"top": "1", "transfer_time": "0,0", "first_mile_mode": "0", "first_mile_time": "1", "last_mile_mode": "0", "last_mile_time": "1"}},
		{"reversed transfer window", &pb.MaasPlanRequest{TransferTimeMin: 40, TransferTimeMax: 10}, map[string]string{"transfer_time": "10,40"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.request.FromLat, tc.request.FromLon = 25.1234567, 121.1234567
			tc.request.ToLat, tc.request.ToLon = 24.9876543, 120.9876543
			tc.request.Date, tc.request.Time = "2026-10-10", "12:34"
			tc.request.ArriveBy = true
			server := &MaasServer{maasClient: resty.New()}
			request := server.tdxRoutingRequest(t.Context(), tc.request, &tdxAPIResponse{})
			for key, want := range tc.want {
				if got := request.QueryParam.Get(key); got != want {
					t.Errorf("%s = %q, want %q", key, got, want)
				}
			}
			if got := request.QueryParam.Get("origin"); got != "25.123457,121.123457" {
				t.Errorf("origin = %q", got)
			}
			if got := request.QueryParam.Get("destination"); got != "24.987654,120.987654" {
				t.Errorf("destination = %q", got)
			}
			if got := request.QueryParam.Get("depart"); got != "2026-10-10T12:34:00" {
				t.Errorf("depart = %q", got)
			}
		})
	}
}

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

func TestWalkClassificationAcceptsIncompleteTDXModeAndExplicitWalking(t *testing.T) {
	for _, tc := range []struct {
		typeName, mode string
		want           bool
	}{
		{"pedestrian", "BUS", true},
		{"PEDESTRIAN", "MRT", true},
		{"transit", "", true},
		{"transit", "WaLk", true},
		{"transit", "BUS", false},
	} {
		if got := isWalkSection(tdxSection{Type: tc.typeName, Transport: tdxTransport{Mode: tc.mode}}); got != tc.want {
			t.Errorf("walk %s/%s = %v, want %v", tc.typeName, tc.mode, got, tc.want)
		}
	}
}

func TestWalkStepsOnlyAttachCompleteManeuverCoordinates(t *testing.T) {
	for _, coordinates := range [][]float64{nil, {121}, {121, 25}, {121, 25, 7}} {
		route := osrmRoute{Legs: []osrmLeg{{Steps: []osrmStep{{Distance: 12, Duration: 4.9, Name: "道路", Maneuver: osrmManeuver{Type: "turn", Modifier: "left", Location: coordinates}}}}}}
		steps := osrmWalkSteps(route)
		if len(steps) != 1 || steps[0].Instruction != "左轉進入道路" || steps[0].DistanceMeters != 12 || steps[0].DurationSeconds != 4 || steps[0].ManeuverType != "turn" || steps[0].Modifier != "left" {
			t.Fatalf("walk steps = %v", steps)
		}
		if len(coordinates) < 2 {
			if steps[0].Location != nil {
				t.Fatalf("incomplete maneuver coordinates = %v", steps[0].Location)
			}
		} else if steps[0].Location == nil || steps[0].Location.Lng != 121 || steps[0].Location.Lat != 25 {
			t.Fatalf("maneuver coordinates = %v", steps[0].Location)
		}
	}
}

func TestWalkCoordinatesAndOSRMResponseRequireUsableData(t *testing.T) {
	for _, tc := range []struct {
		location *pb.Location
		want     bool
	}{{nil, false}, {&pb.Location{}, false}, {&pb.Location{Lat: 25}, true}, {&pb.Location{Lng: 121}, true}, {&pb.Location{Lat: 25, Lng: 121}, true}} {
		if got := walkLocationUsable(tc.location); got != tc.want {
			t.Errorf("location %v usable = %v, want %v", tc.location, got, tc.want)
		}
	}
	for _, tc := range []struct {
		status int
		code   string
		routes int
		want   bool
	}{{200, "Ok", 1, true}, {201, "Ok", 1, true}, {500, "Ok", 1, false}, {200, "NoRoute", 1, false}, {200, "Ok", 0, false}} {
		response := &resty.Response{RawResponse: &http.Response{StatusCode: tc.status}}
		payload := osrmRouteResponse{Code: tc.code, Routes: make([]osrmRoute, tc.routes)}
		if got := osrmRouteAvailable(response, payload); got != tc.want {
			t.Errorf("OSRM %d/%s/%d available = %v", tc.status, tc.code, tc.routes, got)
		}
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
