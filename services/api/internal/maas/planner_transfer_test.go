package maas

import (
	"errors"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/pashagolub/pgxmock/v4"
	"google.golang.org/protobuf/proto"
)

func transferTestLeg(t *testing.T, kind pb.PlannerLegKind, start, end string, duration int64) *pb.PlannerLeg {
	t.Helper()
	leg := &pb.PlannerLeg{Kind: kind, DurationSeconds: duration}
	if start != "" {
		leg.StartTime = plannerTestTime(t, start)
	}
	if end != "" {
		leg.EndTime = plannerTestTime(t, end)
	}
	return leg
}

func TestPlannerTransfersMeasureSlackAfterTheWalk(t *testing.T) {
	const transit, walk = pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT, pb.PlannerLegKind_PLANNER_LEG_KIND_WALK
	legs := []*pb.PlannerLeg{
		transferTestLeg(t, walk, "", "", 600),
		transferTestLeg(t, transit, "08:00:00", "08:20:00", 1200),
		transferTestLeg(t, walk, "", "", 60),
		transferTestLeg(t, walk, "", "", 59),
		transferTestLeg(t, transit, "08:25:00", "08:40:00", 900),
		transferTestLeg(t, walk, "", "", 120),
		transferTestLeg(t, transit, "08:45:00", "09:00:00", 900),
		transferTestLeg(t, walk, "", "", 300),
	}
	for _, tc := range []struct {
		buffer, wantBuffered int64
		wantMargins          [2]int64
	}{
		{0, 0, [2]int64{181, 180}},
		// The buffer MOTIS added to each walk is slack, not walking.
		{60, 120, [2]int64{241, 240}},
		// A walk shorter than the buffer gives back only what it walked.
		{200, 239, [2]int64{300, 300}},
	} {
		got, buffered := plannerTransfers(legs, nil, tc.buffer)
		want := []*pb.PlannerTransfer{
			{FromLeg: 1, ToLeg: 4, MarginSeconds: tc.wantMargins[0], Level: pb.TransferLevel_TRANSFER_LEVEL_COMFORTABLE},
			{FromLeg: 4, ToLeg: 6, MarginSeconds: tc.wantMargins[1], Level: pb.TransferLevel_TRANSFER_LEVEL_COMFORTABLE},
		}
		if len(got) != len(want) || buffered != tc.wantBuffered {
			t.Fatalf("buffer %d: transfers = %v, buffered = %d", tc.buffer, got, buffered)
		}
		for i := range want {
			if !proto.Equal(got[i], want[i]) {
				t.Errorf("buffer %d: transfer %d = %v, want %v", tc.buffer, i, got[i], want[i])
			}
		}
	}
	if transfers, buffered := plannerTransfers(legs[:2], nil, 60); len(transfers) != 0 || buffered != 0 {
		t.Fatalf("one transit leg has transfers %v, buffered %d", transfers, buffered)
	}
}

func TestTransferLevelThresholdAndMissingTimes(t *testing.T) {
	timed := &pb.PlannerLeg{StartTime: plannerTestTime(t, "08:00:00"), EndTime: plannerTestTime(t, "08:00:00")}
	untimed := &pb.PlannerLeg{}
	tests := []struct {
		name     string
		from, to *pb.PlannerLeg
		margin   int64
		want     pb.TransferLevel
	}{
		{"at threshold", timed, timed, 180, pb.TransferLevel_TRANSFER_LEVEL_COMFORTABLE},
		{"under threshold", timed, timed, 179, pb.TransferLevel_TRANSFER_LEVEL_TIGHT},
		{"missed", timed, timed, -60, pb.TransferLevel_TRANSFER_LEVEL_TIGHT},
		{"no arrival time", untimed, timed, 3600, pb.TransferLevel_TRANSFER_LEVEL_UNSPECIFIED},
		{"no departure time", timed, untimed, 3600, pb.TransferLevel_TRANSFER_LEVEL_UNSPECIFIED},
	}
	for _, tt := range tests {
		if got := transferLevel(tt.from, tt.to, tt.margin); got != tt.want {
			t.Errorf("%s = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// Only the leg arrived on decides: an estimated departing leg has not run yet.
// An estimate flags the times without making the transfer read tight.
func TestAddPlannerTransfersReadsTheArrivingLegEstimate(t *testing.T) {
	const transit = pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT
	arriving := transferTestLeg(t, transit, "08:00:00", "08:20:00", 1200)
	departing := transferTestLeg(t, transit, "08:40:00", "09:00:00", 1200)
	response := &pb.PlannerResponse{Itineraries: []*pb.PlannerItinerary{{Legs: []*pb.PlannerLeg{arriving, departing}}}}
	addPlannerTransfers(response, map[*pb.PlannerLeg]bool{departing: true}, 0)
	if got := response.Itineraries[0].Transfers; len(got) != 1 || got[0].TimesEstimated {
		t.Fatalf("departing estimate = %v", got)
	}
	addPlannerTransfers(response, map[*pb.PlannerLeg]bool{arriving: true}, 0)
	if got := response.Itineraries[0].Transfers; !got[0].TimesEstimated || got[0].Level != pb.TransferLevel_TRANSFER_LEVEL_COMFORTABLE {
		t.Fatalf("arriving estimate = %v", got)
	}
}

func TestAddPlannerTransfersTakesTheBufferOutOfTheWalking(t *testing.T) {
	const transit, walk = pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT, pb.PlannerLegKind_PLANNER_LEG_KIND_WALK
	itinerary := &pb.PlannerItinerary{WalkSeconds: 900, Legs: []*pb.PlannerLeg{
		transferTestLeg(t, walk, "", "", 300),
		transferTestLeg(t, transit, "08:00:00", "08:20:00", 1200),
		transferTestLeg(t, walk, "", "", 300),
		transferTestLeg(t, transit, "08:30:00", "09:00:00", 1800),
		transferTestLeg(t, walk, "", "", 300),
	}}
	addPlannerTransfers(&pb.PlannerResponse{Itineraries: []*pb.PlannerItinerary{itinerary}}, nil, 240)
	if itinerary.WalkSeconds != 660 || itinerary.Transfers[0].MarginSeconds != 540 {
		t.Fatalf("walk = %d, margin = %d, want 660 and 540", itinerary.WalkSeconds, itinerary.Transfers[0].MarginSeconds)
	}
}

func TestBusTripRouteAndStopUIDParseMotisIDs(t *testing.T) {
	for id, want := range map[string]struct {
		subRoute  string
		direction int32
		ok        bool
	}{
		"20270101_07:55_taiwan_TPE157462:1:0755:1111100": {"TPE157462", 1, true},
		"20270101_07:55_taiwan_TPE157462:0":              {"TPE157462", 0, true},
		"07:55_taiwan_TPE157462:1:0755:1111100":          {},
		"20270101_07:55_taiwan_TPE157462":                {},
		"20270101_07:55_taiwan_TPE157462:x:0755":         {},
	} {
		subRoute, direction, ok := busTripRoute(id)
		if subRoute != want.subRoute || direction != want.direction || ok != want.ok {
			t.Errorf("%s = %q/%d/%v, want %v", id, subRoute, direction, ok, want)
		}
	}
	for id, want := range map[string]string{"taiwan_TPE1": "TPE1", "TPE1": "", "taiwan_": ""} {
		if got, ok := gtfsStopUID(id); got != want || ok != (want != "") {
			t.Errorf("%s = %q/%v", id, got, ok)
		}
	}
}

func busPlannerLeg(mode pb.PlannerTransitMode, trip, from, to string) *pb.PlannerLeg {
	return &pb.PlannerLeg{
		Mode:    mode,
		Transit: &pb.PlannerTransit{TripId: trip},
		From:    &pb.PlannerStop{StopId: from},
		To:      &pb.PlannerStop{StopId: to},
	}
}

func TestEstimatedLegsBatchesOnlyResolvableBusLegs(t *testing.T) {
	const trip = "20270101_07:55_taiwan_TPE157462:1:0755:1111100"
	bus := busPlannerLeg(pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS, trip, "taiwan_A", "taiwan_B")
	coach := busPlannerLeg(pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_COACH, "20270101_09:00_taiwan_THB9:0:0900:1", "taiwan_C", "taiwan_D")
	pairs := []plannerPair{
		{leg: busPlannerLeg(pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_SUBWAY, trip, "taiwan_A", "taiwan_B")},
		{leg: busPlannerLeg(pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS, "M:TRTC", "taiwan_A", "taiwan_B")},
		{leg: busPlannerLeg(pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS, trip, "A", "taiwan_B")},
		{leg: busPlannerLeg(pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS, trip, "taiwan_A", "B")},
		{leg: bus}, {leg: coach},
	}
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery("bus_segment_time").
		WithArgs([]int32{0, 1}, []string{"TPE157462", "THB9"}, []int32{1, 0}, []string{"A", "C"}, []string{"B", "D"}).
		WillReturnRows(pgxmock.NewRows([]string{"leg_index"}).AddRow(int32(1))).RowsWillBeClosed()
	got := estimatedLegs(t.Context(), db, pairs)
	if len(got) != 1 || !got[coach] {
		t.Fatalf("estimated = %v", got)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
	if estimatedLegs(t.Context(), nil, pairs) != nil || estimatedLegs(t.Context(), db, pairs[:4]) != nil {
		t.Fatal("no database or no resolvable bus leg must not query")
	}
}

func TestEstimatedLegsSurviveDatabaseFailures(t *testing.T) {
	legs := []*pb.PlannerLeg{{}, {}}
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery("bus_segment_time").WillReturnError(errors.New("down"))
	if got := queryEstimatedLegs(t.Context(), db, busSegmentBatch{legs: legs}); got != nil {
		t.Fatalf("query failure = %v", got)
	}

	scanFailure := pgxmock.NewRows([]string{"leg_index"}).AddRow(int32(0)).AddRow("invalid").AddRow(int32(1))
	if got := readEstimatedLegs(maasRows(t, scanFailure), legs); len(got) != 1 || !got[legs[0]] {
		t.Fatalf("scan failure kept %v", got)
	}
	iterateFailure := pgxmock.NewRows([]string{"leg_index"}).AddRow(int32(1)).CloseError(errors.New("interrupted"))
	if got := readEstimatedLegs(maasRows(t, iterateFailure), legs); len(got) != 1 || !got[legs[1]] {
		t.Fatalf("iteration failure kept %v", got)
	}
}
