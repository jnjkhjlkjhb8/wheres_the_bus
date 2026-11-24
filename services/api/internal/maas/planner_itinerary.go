package maas

import (
	"crypto/sha256"
	"fmt"
	"slices"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/protobuf/types/known/timestamppb"
)

var _plannerTransitModes = map[string]pb.PlannerTransitMode{
	"Bus":        pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS,
	"HighwayBus": pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_COACH,
	"Subway":     pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_SUBWAY,
	"Tram":       pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_TRAM,
	"THSR":       pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_HIGH_SPEED_RAIL,
	"Rail":       pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_RAIL,
	"Ferry":      pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_FERRY,
	"CableCar":   pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_CABLE_CAR,
}

var _plannerStreetKinds = map[string]pb.PlannerLegKind{
	"WALK":        pb.PlannerLegKind_PLANNER_LEG_KIND_WALK,
	"BIKE":        pb.PlannerLegKind_PLANNER_LEG_KIND_BIKE,
	"RENTAL":      pb.PlannerLegKind_PLANNER_LEG_KIND_RENTAL,
	"CAR":         pb.PlannerLegKind_PLANNER_LEG_KIND_CAR,
	"CAR_PARKING": pb.PlannerLegKind_PLANNER_LEG_KIND_CAR,
	"CAR_DROPOFF": pb.PlannerLegKind_PLANNER_LEG_KIND_CAR,
}

// plannerPair ties a PlannerService leg to the MaasService section built from
// the same MOTIS leg, whose lookups and geometry it borrows.
type plannerPair struct {
	leg     *pb.PlannerLeg
	section *pb.Section
}

// plannerResponse relies on convertRoutes keeping one route per itinerary and
// one section per leg, in MOTIS's order.
func plannerResponse(plan *motisPlanResponse, legacy *pb.MaasPlanResponse) (*pb.PlannerResponse, []plannerPair) {
	out := &pb.PlannerResponse{
		PreviousPageCursor: plan.PreviousPageCursor,
		NextPageCursor:     plan.NextPageCursor,
	}
	var pairs []plannerPair
	for i, itinerary := range plan.Itineraries {
		route := legacy.Routes[i]
		converted := plannerItinerary(itinerary, route)
		for j, leg := range converted.Legs {
			pairs = append(pairs, plannerPair{leg: leg, section: route.Sections[j]})
		}
		out.Itineraries = append(out.Itineraries, converted)
	}
	return out, pairs
}

func plannerItinerary(itinerary motisItinerary, route *pb.Route) *pb.PlannerItinerary {
	legs := make([]*pb.PlannerLeg, len(itinerary.Legs))
	for j, leg := range itinerary.Legs {
		legs[j] = plannerLeg(leg, route.Sections[j])
	}
	return &pb.PlannerItinerary{
		Id:              plannerItineraryID(itinerary),
		StartTime:       plannerTime(itinerary.StartTime),
		EndTime:         plannerTime(itinerary.EndTime),
		DurationSeconds: itinerary.Duration,
		TransferCount:   itinerary.Transfers,
		WalkSeconds:     plannerWalkSeconds(legs),
		TotalFare:       route.TotalFare,
		FareComplete:    plannerFareComplete(legs),
		Legs:            legs,
	}
}

func plannerLeg(leg motisLeg, section *pb.Section) *pb.PlannerLeg {
	return &pb.PlannerLeg{
		Kind:                 plannerLegKind(leg.Mode),
		Mode:                 _plannerTransitModes[motisTransitMode(leg.Mode)],
		From:                 plannerStop(leg.From),
		To:                   plannerStop(leg.To),
		StartTime:            plannerTime(leg.StartTime),
		EndTime:              plannerTime(leg.EndTime),
		DurationSeconds:      leg.Duration,
		DistanceMeters:       leg.Distance,
		Transit:              plannerTransit(leg),
		IntermediateStops:    plannerStops(leg.IntermediateStops),
		NotificationIdentity: section.NotificationIdentity,
		Fare:                 section.Fare,
		Alternatives:         plannerAlternatives(leg.Alternatives, section.Alternatives),
	}
}

// plannerAlternatives walks the same filter addMotisAlternatives applied, so
// the k-th kept alternative is the k-th converted section.
func plannerAlternatives(alternatives [][]motisLeg, sections []*pb.Section) []*pb.PlannerLeg {
	var out []*pb.PlannerLeg
	for _, alternative := range alternatives {
		transit, ok := motisAlternativeLeg(alternative)
		if !ok {
			continue
		}
		// convertAlternative builds no nested alternatives to pair with.
		transit.Alternatives = nil
		out = append(out, plannerLeg(transit, sections[len(out)]))
	}
	return out
}

func plannerLegKind(mode string) pb.PlannerLegKind {
	if motisTransitMode(mode) != "" {
		return pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT
	}
	return _plannerStreetKinds[mode]
}

func plannerTransit(leg motisLeg) *pb.PlannerTransit {
	if motisTransitMode(leg.Mode) == "" {
		return nil
	}
	transit := &pb.PlannerTransit{
		TripId:             leg.TripID,
		RouteId:            leg.RouteID,
		ScheduledDeparture: plannerTime(leg.ScheduledStartTime),
		ScheduledArrival:   plannerTime(leg.ScheduledEndTime),
		RealTime:           leg.RealTime,
		Name:               motisRouteName(leg),
		ShortName:          leg.RouteShortName,
		LongName:           leg.RouteLongName,
		Headsign:           leg.Headsign,
		RouteColor:         leg.RouteColor,
	}
	if leg.AgencyName != "" {
		transit.Agency = &pb.Agency{AgencyId: leg.AgencyID, Name: leg.AgencyName, Website: leg.AgencyURL}
	}
	return transit
}

func plannerStops(places []motisPlace) []*pb.PlannerStop {
	stops := make([]*pb.PlannerStop, 0, len(places))
	for _, place := range places {
		stops = append(stops, plannerStop(place))
	}
	return stops
}

func plannerStop(place motisPlace) *pb.PlannerStop {
	return &pb.PlannerStop{
		Name:      place.Name,
		StopId:    place.StopID,
		Location:  &pb.Location{Lat: place.Lat, Lng: place.Lon},
		Arrival:   plannerTime(place.Arrival),
		Departure: plannerTime(place.Departure),
	}
}

// plannerTime leaves a missing or malformed time unset rather than the epoch.
func plannerTime(ts string) *timestamppb.Timestamp {
	parsed, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return nil
	}
	return timestamppb.New(parsed)
}

func plannerItineraryID(itinerary motisItinerary) string {
	if itinerary.ID != "" {
		return itinerary.ID
	}
	hash := sha256.New()
	for _, leg := range itinerary.Legs {
		_, _ = fmt.Fprintf(hash, "%s|%s|%s|%.6f,%.6f|%s|%.6f,%.6f|%s|%s\n",
			leg.Mode, leg.TripID,
			leg.From.StopID, leg.From.Lat, leg.From.Lon,
			leg.To.StopID, leg.To.Lat, leg.To.Lon,
			leg.ScheduledStartTime, leg.ScheduledEndTime)
	}
	return fmt.Sprintf("sha256:%x", hash.Sum(nil)[:16])
}

func plannerWalkSeconds(legs []*pb.PlannerLeg) int64 {
	var walk int64
	for _, leg := range legs {
		if leg.Kind == pb.PlannerLegKind_PLANNER_LEG_KIND_WALK {
			walk += leg.DurationSeconds
		}
	}
	return walk
}

// plannerFareComplete is false as soon as one transit leg went unpriced: bus
// legs never resolve a fare, and a partial sum must not read as cheap.
func plannerFareComplete(legs []*pb.PlannerLeg) bool {
	for _, leg := range legs {
		if leg.Kind == pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT && leg.Fare <= 0 {
			return false
		}
	}
	return true
}

// copyPlannerGeometry runs after enrich: a section carries either a walk path
// or a transit path, never both.
func copyPlannerGeometry(pairs []plannerPair) {
	for _, pair := range pairs {
		pair.leg.Path = slices.Concat(pair.section.WalkPath, pair.section.TransitPath)
		pair.leg.WalkSteps = pair.section.WalkSteps
	}
}
