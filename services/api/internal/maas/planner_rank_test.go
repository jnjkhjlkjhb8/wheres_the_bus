package maas

import (
	"strings"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

type rankCase struct {
	id              string
	duration, walk  int64
	transfers, fare int32
	complete        bool
}

func rankFixture(cases ...rankCase) *pb.PlannerResponse {
	response := &pb.PlannerResponse{PreviousPageCursor: "earlier", NextPageCursor: "later"}
	for _, c := range cases {
		response.Itineraries = append(response.Itineraries, &pb.PlannerItinerary{
			Id: c.id, DurationSeconds: c.duration, WalkSeconds: c.walk,
			TransferCount: c.transfers, TotalFare: c.fare, FareComplete: c.complete,
		})
	}
	return response
}

func rankedIDs(response *pb.PlannerResponse) string {
	ids := make([]string, 0, len(response.Itineraries))
	for _, itinerary := range response.Itineraries {
		ids = append(ids, itinerary.Id)
	}
	return strings.Join(ids, ",")
}

// Each sort's first axis decides, and each tie falls through to the next
// listed axis; a full tie keeps MOTIS's order.
func TestPlannerSortsOrderByTheirAxisThenTieBreaks(t *testing.T) {
	tests := []struct {
		sort  pb.PlannerSort
		cases []rankCase
		want  string
	}{
		{pb.PlannerSort_PLANNER_SORT_FASTEST, []rankCase{
			{id: "slow", duration: 200}, {id: "walky", duration: 100, transfers: 1, walk: 90},
			{id: "changes", duration: 100, transfers: 2}, {id: "best", duration: 100, transfers: 1, walk: 10},
			{id: "tie", duration: 100, transfers: 1, walk: 10},
		}, "best,tie,walky,changes,slow"},
		{pb.PlannerSort_PLANNER_SORT_CHEAPEST, []rankCase{
			{id: "partial", fare: 5, duration: 30}, {id: "dear", fare: 50, duration: 100, complete: true},
			{id: "slow", fare: 30, duration: 300, complete: true}, {id: "cheap", fare: 30, duration: 250, transfers: 2, complete: true},
			{id: "cheaper", fare: 30, duration: 250, transfers: 1, complete: true}, {id: "unknown", duration: 40},
		}, "cheaper,cheap,slow,dear,partial,unknown"},
		{pb.PlannerSort_PLANNER_SORT_FEWEST_TRANSFERS, []rankCase{
			{id: "two", transfers: 2}, {id: "one-slow", transfers: 1, duration: 200},
			{id: "one-walky", transfers: 1, duration: 100, walk: 60}, {id: "one", transfers: 1, duration: 100, walk: 30},
		}, "one,one-walky,one-slow,two"},
		{pb.PlannerSort_PLANNER_SORT_LEAST_WALKING, []rankCase{
			{id: "far", walk: 600}, {id: "slow", walk: 60, duration: 200},
			{id: "changes", walk: 60, duration: 100, transfers: 2}, {id: "best", walk: 60, duration: 100, transfers: 1},
		}, "best,changes,slow,far"},
		// An unset or unknown sort is FASTEST.
		{pb.PlannerSort_PLANNER_SORT_UNSPECIFIED, []rankCase{{id: "b", duration: 2}, {id: "a", duration: 1}}, "a,b"},
		{pb.PlannerSort(99), []rankCase{{id: "b", duration: 2}, {id: "a", duration: 1}}, "a,b"},
	}
	for _, tt := range tests {
		t.Run(tt.sort.String(), func(t *testing.T) {
			full := rankFixture(tt.cases...)
			got := rankPlanner(full, &pb.PlannerRequest{Sort: tt.sort, Top: 10})
			if rankedIDs(got) != tt.want {
				t.Fatalf("order = %s, want %s", rankedIDs(got), tt.want)
			}
			if full.Itineraries[0].Id != tt.cases[0].id {
				t.Fatal("ranking reordered the cached set")
			}
		})
	}
}

func TestPlannerRankTrimsToTopAndKeepsCursors(t *testing.T) {
	cases := make([]rankCase, 0, 7)
	for i := range 7 {
		cases = append(cases, rankCase{id: string(rune('a' + i)), duration: int64(i)})
	}
	for top, want := range map[int32]string{0: "a,b,c,d,e", 2: "a,b", 10: "a,b,c,d,e,f,g"} {
		got := rankPlanner(rankFixture(cases...), &pb.PlannerRequest{Top: top})
		if rankedIDs(got) != want || got.PreviousPageCursor != "earlier" || got.NextPageCursor != "later" {
			t.Errorf("top %d = %s (%q/%q), want %s", top, rankedIDs(got), got.PreviousPageCursor, got.NextPageCursor, want)
		}
	}
}
