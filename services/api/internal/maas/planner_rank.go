package maas

import (
	"cmp"
	"slices"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

type itineraryAxis func(*pb.PlannerItinerary) int64

var _plannerSortAxes = map[pb.PlannerSort][]itineraryAxis{
	pb.PlannerSort_PLANNER_SORT_FASTEST:          {byTravelTime, byTransfers, byWalking},
	pb.PlannerSort_PLANNER_SORT_CHEAPEST:         {byUnpriced, byKnownFare, byTravelTime, byTransfers},
	pb.PlannerSort_PLANNER_SORT_FEWEST_TRANSFERS: {byTransfers, byTravelTime, byWalking},
	pb.PlannerSort_PLANNER_SORT_LEAST_WALKING:    {byWalking, byTravelTime, byTransfers},
}

func byTravelTime(itinerary *pb.PlannerItinerary) int64 { return itinerary.DurationSeconds }
func byTransfers(itinerary *pb.PlannerItinerary) int64  { return int64(itinerary.TransferCount) }
func byWalking(itinerary *pb.PlannerItinerary) int64    { return itinerary.WalkSeconds }

func byUnpriced(itinerary *pb.PlannerItinerary) int64 {
	if itinerary.FareComplete {
		return 0
	}
	return 1
}

// byKnownFare ignores a partial sum, which byUnpriced has already ordered last.
func byKnownFare(itinerary *pb.PlannerItinerary) int64 {
	if !itinerary.FareComplete {
		return 0
	}
	return int64(itinerary.TotalFare)
}

// rankPlanner orders a copy, so the cached set keeps MOTIS's order and every
// sort, including a repeated one, starts from the same input.
func rankPlanner(full *pb.PlannerResponse, req *pb.PlannerRequest) *pb.PlannerResponse {
	axes, ok := _plannerSortAxes[req.GetSort()]
	if !ok {
		axes = _plannerSortAxes[pb.PlannerSort_PLANNER_SORT_FASTEST]
	}
	ranked := slices.Clone(full.Itineraries)
	slices.SortStableFunc(ranked, func(a, b *pb.PlannerItinerary) int {
		return compareItineraries(axes, a, b)
	})
	limit := int(clampInt(req.GetTop(), 1, 10, 5))
	return &pb.PlannerResponse{
		Itineraries:        ranked[:min(limit, len(ranked))],
		PreviousPageCursor: full.PreviousPageCursor,
		NextPageCursor:     full.NextPageCursor,
	}
}

func compareItineraries(axes []itineraryAxis, a, b *pb.PlannerItinerary) int {
	for _, axis := range axes {
		if order := cmp.Compare(axis(a), axis(b)); order != 0 {
			return order
		}
	}
	return 0
}
