package maas

import (
	"strings"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func plannerTestTime(t *testing.T, clock string) *timestamppb.Timestamp {
	t.Helper()
	return timestamppb.New(mustParseRFC3339(t, "2027-01-01T"+clock+"+08:00"))
}

func TestPlannerLegCarriesTripIdentityAndSectionLookups(t *testing.T) {
	leg := motisLeg{
		Mode: "BUS", Duration: 1200, Distance: 0,
		StartTime: "2027-01-01T08:01:00+08:00", EndTime: "2027-01-01T08:21:00+08:00",
		ScheduledStartTime: "2027-01-01T08:00:00+08:00", ScheduledEndTime: "2027-01-01T08:20:00+08:00",
		RealTime: true, TripID: "trip", RouteID: "route",
		DisplayName: "307 區", RouteShortName: "307", RouteLongName: "公館-板橋", Headsign: "板橋", RouteColor: "ff0000",
		AgencyID: "A1", AgencyName: "首都客運", AgencyURL: "https://example.test",
		From:              motisPlace{Name: "公館", StopID: "taiwan_TPE1", Lat: 25.01, Lon: 121.53, Departure: "2027-01-01T08:01:00+08:00"},
		To:                motisPlace{Name: "台電大樓", StopID: "taiwan_TPE3", Lat: 25.02, Lon: 121.52, Arrival: "2027-01-01T08:21:00+08:00"},
		IntermediateStops: []motisPlace{{Name: "師大分部", Arrival: "2027-01-01T08:10:00+08:00", Departure: "2027-01-01T08:10:30+08:00"}},
	}
	identity := &pb.NotificationIdentity{RouteKey: "TPE157462", Supported: true}
	got := plannerLeg(leg, &pb.Section{NotificationIdentity: identity, Fare: 15})
	want := &pb.PlannerLeg{
		Kind: pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT, Mode: pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS,
		From:      &pb.PlannerStop{Name: "公館", StopId: "taiwan_TPE1", Location: &pb.Location{Lat: 25.01, Lng: 121.53}, Departure: plannerTestTime(t, "08:01:00")},
		To:        &pb.PlannerStop{Name: "台電大樓", StopId: "taiwan_TPE3", Location: &pb.Location{Lat: 25.02, Lng: 121.52}, Arrival: plannerTestTime(t, "08:21:00")},
		StartTime: plannerTestTime(t, "08:01:00"), EndTime: plannerTestTime(t, "08:21:00"), DurationSeconds: 1200,
		Transit: &pb.PlannerTransit{
			TripId: "trip", RouteId: "route", RealTime: true,
			ScheduledDeparture: plannerTestTime(t, "08:00:00"), ScheduledArrival: plannerTestTime(t, "08:20:00"),
			Name: "307 區", ShortName: "307", LongName: "公館-板橋", Headsign: "板橋", RouteColor: "ff0000",
			Agency: &pb.Agency{AgencyId: "A1", Name: "首都客運", Website: "https://example.test"},
		},
		IntermediateStops: []*pb.PlannerStop{{
			Name: "師大分部", Location: &pb.Location{},
			Arrival: plannerTestTime(t, "08:10:00"), Departure: plannerTestTime(t, "08:10:30"),
		}},
		NotificationIdentity: identity, Fare: 15,
	}
	if !proto.Equal(got, want) {
		t.Fatalf("leg\n got %v\nwant %v", got, want)
	}
}

func TestPlannerStreetLegHasNoTransitAndKeepsItsKind(t *testing.T) {
	for mode, kind := range map[string]pb.PlannerLegKind{
		"WALK": pb.PlannerLegKind_PLANNER_LEG_KIND_WALK, "BIKE": pb.PlannerLegKind_PLANNER_LEG_KIND_BIKE,
		"RENTAL": pb.PlannerLegKind_PLANNER_LEG_KIND_RENTAL, "CAR": pb.PlannerLegKind_PLANNER_LEG_KIND_CAR,
		"CAR_PARKING": pb.PlannerLegKind_PLANNER_LEG_KIND_CAR, "CAR_DROPOFF": pb.PlannerLegKind_PLANNER_LEG_KIND_CAR,
		"FLEX": pb.PlannerLegKind_PLANNER_LEG_KIND_UNSPECIFIED,
	} {
		got := plannerLeg(motisLeg{Mode: mode, Distance: 350, StartTime: "not a time"}, &pb.Section{})
		if got.Kind != kind || got.Mode != pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_UNSPECIFIED || got.Transit != nil {
			t.Errorf("%s: kind=%v mode=%v transit=%v", mode, got.Kind, got.Mode, got.Transit)
		}
		if got.DistanceMeters != 350 || got.StartTime != nil {
			t.Errorf("%s: distance=%v start=%v", mode, got.DistanceMeters, got.StartTime)
		}
	}
	if transit := plannerTransit(motisLeg{Mode: "SUBWAY"}); transit == nil || transit.Agency != nil {
		t.Fatalf("transit without an agency = %v", transit)
	}
}

func TestPlannerTransitModesFollowTheSectionModes(t *testing.T) {
	for motis, want := range map[string]pb.PlannerTransitMode{
		"BUS": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS, "COACH": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_COACH,
		"SUBWAY": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_SUBWAY, "TRAM": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_TRAM,
		"HIGHSPEED_RAIL": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_HIGH_SPEED_RAIL,
		"REGIONAL_RAIL":  pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_RAIL, "LONG_DISTANCE": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_RAIL,
		"FERRY": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_FERRY, "FUNICULAR": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_CABLE_CAR,
	} {
		if got := plannerLeg(motisLeg{Mode: motis}, &pb.Section{}); got.Mode != want || got.Kind != pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT {
			t.Errorf("%s = %v/%v, want %v", motis, got.Mode, got.Kind, want)
		}
	}
}

// Alternatives pair with sections by position among the kept ones, so a
// walk-only alternative must be skipped on both sides.
func TestPlannerAlternativesPairWithKeptSections(t *testing.T) {
	alternatives := [][]motisLeg{
		{{Mode: "WALK"}},
		{{Mode: "WALK"}, {Mode: "BUS", TripID: "later", Alternatives: [][]motisLeg{{{Mode: "BUS"}}}}},
		{{Mode: "BUS", TripID: "latest"}},
	}
	later := &pb.NotificationIdentity{RouteKey: "later"}
	latest := &pb.NotificationIdentity{RouteKey: "latest"}
	got := plannerAlternatives(alternatives, []*pb.Section{{NotificationIdentity: later}, {NotificationIdentity: latest}})
	if len(got) != 2 || got[0].Transit.TripId != "later" || got[0].NotificationIdentity != later || got[1].NotificationIdentity != latest {
		t.Fatalf("alternatives = %v", got)
	}
	if len(got[0].Alternatives) != 0 {
		t.Fatal("an alternative must not carry alternatives of its own")
	}
}

func TestPlannerItinerarySummarisesItsLegs(t *testing.T) {
	itinerary := motisItinerary{
		ID: "motis-id", Duration: 1800, Transfers: 1,
		StartTime: "2027-01-01T08:00:00+08:00", EndTime: "2027-01-01T08:30:00+08:00",
		Legs: []motisLeg{
			{Mode: "WALK", Duration: 120}, {Mode: "SUBWAY"}, {Mode: "WALK", Duration: 60},
			{Mode: "BIKE", Duration: 500}, {Mode: "REGIONAL_RAIL"},
		},
	}
	route := &pb.Route{TotalFare: 45, Sections: []*pb.Section{{}, {Fare: 20}, {}, {}, {Fare: 25}}}
	got := plannerItinerary(itinerary, route)
	if got.Id != "motis-id" || got.DurationSeconds != 1800 || got.TransferCount != 1 || got.TotalFare != 45 {
		t.Fatalf("itinerary = %v", got)
	}
	if !proto.Equal(got.StartTime, plannerTestTime(t, "08:00:00")) || !proto.Equal(got.EndTime, plannerTestTime(t, "08:30:00")) {
		t.Fatalf("times = %v / %v", got.StartTime, got.EndTime)
	}
	if got.WalkSeconds != 180 || !got.FareComplete || len(got.Legs) != 5 || got.Legs[4].Fare != 25 {
		t.Fatalf("walk=%d complete=%v legs=%d", got.WalkSeconds, got.FareComplete, len(got.Legs))
	}
	route.Sections[4].Fare = 0
	if plannerItinerary(itinerary, route).FareComplete {
		t.Fatal("an unpriced transit leg left the fare complete")
	}
	walkOnly := plannerItinerary(motisItinerary{Legs: []motisLeg{{Mode: "WALK"}}}, &pb.Route{Sections: []*pb.Section{{}}})
	if !walkOnly.FareComplete {
		t.Fatal("a walk costs nothing, so its fare is complete")
	}
}

func TestPlannerItineraryIDFallsBackToAStableHash(t *testing.T) {
	legs := []motisLeg{{
		Mode: "BUS", TripID: "trip", ScheduledStartTime: "2027-01-01T08:00:00+08:00", ScheduledEndTime: "2027-01-01T08:20:00+08:00",
		StartTime: "2027-01-01T08:03:00+08:00",
		From:      motisPlace{StopID: "a", Lat: 25, Lon: 121}, To: motisPlace{StopID: "b", Lat: 25.1, Lon: 121.1},
	}}
	id := plannerItineraryID(motisItinerary{Legs: legs})
	if !strings.HasPrefix(id, "sha256:") || len(id) != len("sha256:")+32 {
		t.Fatalf("id = %q", id)
	}
	delayed := []motisLeg{legs[0]}
	delayed[0].StartTime = "2027-01-01T08:09:00+08:00"
	if plannerItineraryID(motisItinerary{Legs: delayed}) != id {
		t.Fatal("a delay changed the itinerary id")
	}
	for name, change := range map[string]func(*motisLeg){
		"mode": func(l *motisLeg) { l.Mode = "COACH" }, "trip": func(l *motisLeg) { l.TripID = "other" },
		"from": func(l *motisLeg) { l.From.StopID = "c" }, "to": func(l *motisLeg) { l.To.StopID = "c" },
		"from point": func(l *motisLeg) { l.From.Lat = 26 }, "to point": func(l *motisLeg) { l.To.Lon = 122 },
		"from lon": func(l *motisLeg) { l.From.Lon = 122 }, "to lat": func(l *motisLeg) { l.To.Lat = 26 },
		"scheduled start": func(l *motisLeg) { l.ScheduledStartTime = "2027-01-01T08:10:00+08:00" },
		"scheduled end":   func(l *motisLeg) { l.ScheduledEndTime = "2027-01-01T08:30:00+08:00" },
	} {
		changed := []motisLeg{legs[0]}
		change(&changed[0])
		if plannerItineraryID(motisItinerary{Legs: changed}) == id {
			t.Errorf("changing the %s kept the id", name)
		}
	}
}

func TestPlannerResponsePairsLegsWithSectionsAndCopiesGeometry(t *testing.T) {
	plan := &motisPlanResponse{
		PreviousPageCursor: "earlier", NextPageCursor: "later",
		Itineraries: []motisItinerary{
			{Legs: []motisLeg{{Mode: "WALK"}, {Mode: "SUBWAY"}}},
			{Legs: []motisLeg{{Mode: "BUS"}}},
		},
	}
	walk, subway, bus := &pb.Section{}, &pb.Section{}, &pb.Section{}
	legacy := &pb.MaasPlanResponse{Routes: []*pb.Route{{Sections: []*pb.Section{walk, subway}}, {Sections: []*pb.Section{bus}}}}
	got, pairs := plannerResponse(plan, legacy)
	if got.PreviousPageCursor != "earlier" || got.NextPageCursor != "later" || len(got.Itineraries) != 2 || len(pairs) != 3 {
		t.Fatalf("response=%v pairs=%d", got, len(pairs))
	}
	walk.WalkPath = []*pb.Location{{Lat: 1}}
	walk.WalkSteps = []*pb.WalkStep{{Instruction: "開始步行"}}
	subway.TransitPath = []*pb.Location{{Lat: 2}, {Lat: 3}}
	copyPlannerGeometry(pairs)
	legs := got.Itineraries[0].Legs
	if len(legs[0].Path) != 1 || len(legs[0].WalkSteps) != 1 || len(legs[1].Path) != 2 || len(got.Itineraries[1].Legs[0].Path) != 0 {
		t.Fatalf("geometry walk=%v steps=%v subway=%v", legs[0].Path, legs[0].WalkSteps, legs[1].Path)
	}
}

func TestPlannerTimeLeavesMalformedTimesUnset(t *testing.T) {
	if plannerTime("") != nil || plannerTime("08:00") != nil {
		t.Fatal("a malformed time was published")
	}
	if got := plannerTime("2027-01-01T00:00:00Z"); !got.AsTime().Equal(time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("time = %v", got)
	}
}
