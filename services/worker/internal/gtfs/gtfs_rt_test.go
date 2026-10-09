package gtfs

import (
	"context"
	"testing"
	"time"

	"github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/protobuf/proto"
)

// A Wednesday, so the weekday masks below are unambiguous.
var _gtfsRTWednesday = time.Date(2026, 8, 5, 9, 0, 0, 0, time.UTC)

func gtfsRTTripFor(t *testing.T, tripID, serviceID string, direction int32) (gtfsRTTrip, gtfsRTRouteKey) {
	t.Helper()
	trip, key, ok := parseGTFSRTTrip(tripID, serviceID, direction)
	if !ok {
		t.Fatalf("parseGTFSRTTrip(%q, %q, %d) rejected a trip the test needs", tripID, serviceID, direction)
	}
	return trip, key
}

func gtfsRTDaily(subRouteUID string, direction int32, departures ...string) *models.Bus_DailyTimetables {
	trips := make([]*models.Bus_DailyTimetable, 0, len(departures))
	for _, departure := range departures {
		trips = append(trips, &models.Bus_DailyTimetable{
			StopTimes: []*models.Bus_StopTime{
				// Deliberately out of sequence order: the origin is the lowest
				// StopSequence, not the first element.
				{StopSequence: 2, ArrivalTime: "07:00", DepartureTime: "07:00", StopUID: "S2"},
				{StopSequence: 1, ArrivalTime: departure, DepartureTime: departure, StopUID: "S1"},
			},
		})
	}
	return &models.Bus_DailyTimetables{
		SubRouteUID: subRouteUID,
		Direction: map[int32]*models.Bus_DirectionTimetable{
			direction: {DailyTimetables: trips},
		},
	}
}

func gtfsRTReader(payloads map[string]*models.Bus_DailyTimetables) gtfsRTDailyReader {
	return func(context.Context, []string) (map[string]*models.Bus_DailyTimetables, error) {
		return payloads, nil
	}
}

func gtfsRTCancelledIDs(entities []*gtfs.FeedEntity) []string {
	ids := make([]string, 0, len(entities))
	for _, entity := range entities {
		ids = append(ids, entity.GetTripUpdate().GetTrip().GetTripId())
	}
	return ids
}

func gtfsRTIndexOf(t *testing.T, trips ...[3]string) *gtfsRTIndex {
	t.Helper()
	index := &gtfsRTIndex{builtFor: "2026-08-05", trips: map[gtfsRTRouteKey][]gtfsRTTrip{}}
	for _, spec := range trips {
		direction := int32(0)
		if spec[2] == "1" {
			direction = 1
		}
		trip, key := gtfsRTTripFor(t, spec[0], spec[1], direction)
		index.trips[key] = append(index.trips[key], trip)
	}
	return index
}

func TestParseGTFSRTWeekMaskIsSundayFirst(t *testing.T) {
	// The mask is written Monday-first; the array is read Sunday-first because
	// time.Weekday and EXTRACT(DOW) both start at Sunday. Getting this backwards
	// would cancel a whole weekday's service.
	week, ok := parseGTFSRTWeekMask("W:1111100")
	if !ok {
		t.Fatal("W:1111100 rejected")
	}
	want := [7]bool{false, true, true, true, true, true, false}
	if week != want {
		t.Errorf("Mon-Fri mask = %v, want %v", week, want)
	}
	if _, ok := parseGTFSRTWeekMask("W:11111"); ok {
		t.Error("a short mask was accepted")
	}
	if _, ok := parseGTFSRTWeekMask("D20260805"); ok {
		t.Error("a date service id was accepted as a mask")
	}
}

func TestParseGTFSRTCompactTime(t *testing.T) {
	cases := map[string]struct {
		want int
		ok   bool
	}{
		"610":  {6*60 + 10, true},
		"0610": {6*60 + 10, true},
		"2405": {24*60 + 5, true}, // a service day legitimately runs past midnight
		"61":   {0, false},
		"0670": {0, false},
		"ab10": {0, false},
	}
	for input, want := range cases {
		got, ok := parseGTFSRTCompactTime(input)
		if ok != want.ok || (ok && got != want.want) {
			t.Errorf("parseGTFSRTCompactTime(%q) = %d, %v; want %d, %v", input, got, ok, want.want, want.ok)
		}
	}
}

func TestParseGTFSRTTripCanonicalisesInterCity(t *testing.T) {
	// InterCity encodes direction in the UID suffix; the daily timetable and the
	// ETA keys are canonical, so the index has to match them or every THB route
	// looks like it has no observations at all.
	_, key := gtfsRTTripFor(t, "THB902302:0:0610:W:1111100", "W:1111100", 0)
	if key.subRouteUID != "THB9023" || key.direction != 1 {
		t.Errorf("THB902302 canonicalised to %q dir %d, want THB9023 dir 1", key.subRouteUID, key.direction)
	}
	// A city bus keeps its UID and its stated direction.
	_, cityKey := gtfsRTTripFor(t, "KHH1234:1:0610:W:1111100", "W:1111100", 1)
	if cityKey.subRouteUID != "KHH1234" || cityKey.direction != 1 {
		t.Errorf("KHH1234 canonicalised to %q dir %d, want KHH1234 dir 1", cityKey.subRouteUID, cityKey.direction)
	}
}

func TestParseGTFSRTTripRejectsMalformedIDs(t *testing.T) {
	// A trip that cannot be placed must never be cancellable.
	for _, tripID := range []string{
		"KHH1234:0:0610",           // no service id
		"KHH1234:0:0610:D20260805", // dated service, not a mask
		":0:0610:W:1111100",        // no subroute
		"KHH1234:0::W:1111100",     // no departure
		"KHH1234:7:0610:W:1111100", // impossible direction is caught by the arg
	} {
		if _, _, ok := parseGTFSRTTrip(tripID, "W:1111100", 0); ok && tripID != "KHH1234:7:0610:W:1111100" {
			t.Errorf("parseGTFSRTTrip accepted malformed id %q", tripID)
		}
	}
	if _, _, ok := parseGTFSRTTrip("KHH1234:0:0610:W:1111100", "W:1111100", 2); ok {
		t.Error("parseGTFSRTTrip accepted direction 2")
	}
}

func TestBuildGTFSRTCancellationsReportsTheMissingDeparture(t *testing.T) {
	index := gtfsRTIndexOf(t,
		[3]string{"KHH1:0:0600:W:1111100", "W:1111100", "0"},
		[3]string{"KHH1:0:0630:W:1111100", "W:1111100", "0"},
		[3]string{"KHH1:0:0700:W:1111100", "W:1111100", "0"},
	)
	entities, _, stats := buildGTFSRTCancellations(context.Background(), index, _gtfsRTWednesday,
		gtfsRTReader(map[string]*models.Bus_DailyTimetables{
			"KHH1": gtfsRTDaily("KHH1", 0, "06:00", "07:00"),
		}))
	got := gtfsRTCancelledIDs(entities)
	if len(got) != 1 || got[0] != "KHH1:0:0630:W:1111100" {
		t.Fatalf("cancelled %v, want only KHH1:0:0630:W:1111100", got)
	}
	if stats.routesGateFailed != 0 || stats.cancellations != 1 {
		t.Errorf("stats = %+v, want one cancellation and no gate failure", stats)
	}
	if entities[0].GetTripUpdate().GetTrip().GetScheduleRelationship() != gtfs.TripDescriptor_CANCELED {
		t.Error("entity is not CANCELED")
	}
	if entities[0].GetTripUpdate().GetTrip().GetStartDate() != "20260805" {
		t.Errorf("start_date = %q, want 20260805", entities[0].GetTripUpdate().GetTrip().GetStartDate())
	}
}

func TestBuildGTFSRTCancellationsSilencesASubrouteWithAnUnexplainedDeparture(t *testing.T) {
	// 06:45 is in the daily timetable and in no schedule, which proves the two
	// sources do not agree on how this subroute names a departure. The 06:30 gap
	// is then unexplainable, so nothing at all is emitted.
	index := gtfsRTIndexOf(t,
		[3]string{"KHH1:0:0600:W:1111100", "W:1111100", "0"},
		[3]string{"KHH1:0:0630:W:1111100", "W:1111100", "0"},
	)
	entities, _, stats := buildGTFSRTCancellations(context.Background(), index, _gtfsRTWednesday,
		gtfsRTReader(map[string]*models.Bus_DailyTimetables{
			"KHH1": gtfsRTDaily("KHH1", 0, "06:00", "06:45"),
		}))
	if len(entities) != 0 {
		t.Fatalf("emitted %v, want nothing", gtfsRTCancelledIDs(entities))
	}
	if stats.routesGateFailed != 1 {
		t.Errorf("routes_gate_failed = %d, want 1", stats.routesGateFailed)
	}
}

func TestBuildGTFSRTCancellationsLetsOneObservationSatisfyEveryMask(t *testing.T) {
	// bus_dailytimetable carries no ServiceDay, so two masks that both cover
	// today put two trip_ids behind one observation. Consuming it against only
	// one of them would cancel the other.
	index := gtfsRTIndexOf(t,
		[3]string{"KHH1:0:0600:W:1111100", "W:1111100", "0"},
		[3]string{"KHH1:0:0600:W:1111111", "W:1111111", "0"},
	)
	entities, _, stats := buildGTFSRTCancellations(context.Background(), index, _gtfsRTWednesday,
		gtfsRTReader(map[string]*models.Bus_DailyTimetables{
			"KHH1": gtfsRTDaily("KHH1", 0, "06:00"),
		}))
	if len(entities) != 0 {
		t.Fatalf("emitted %v, want nothing", gtfsRTCancelledIDs(entities))
	}
	if stats.tripsActive != 2 {
		t.Errorf("trips_active = %d, want 2", stats.tripsActive)
	}
}

func TestBuildGTFSRTCancellationsStaysSilentWithoutADailyTimetable(t *testing.T) {
	// Taipei, New Taipei, Tainan, Kinmen and Lienchiang have no daily timetable
	// at all, so absence must never mean withdrawn.
	index := gtfsRTIndexOf(t,
		[3]string{"TPE1:0:0600:W:1111100", "W:1111100", "0"},
		[3]string{"TPE1:0:0630:W:1111100", "W:1111100", "0"},
	)
	entities, _, stats := buildGTFSRTCancellations(context.Background(), index, _gtfsRTWednesday,
		gtfsRTReader(map[string]*models.Bus_DailyTimetables{}))
	if len(entities) != 0 {
		t.Fatalf("emitted %v for a city with no daily timetable", gtfsRTCancelledIDs(entities))
	}
	if stats.routesNoDaily != 1 {
		t.Errorf("routes_no_daily = %d, want 1", stats.routesNoDaily)
	}
}

func TestBuildGTFSRTCancellationsIgnoresTripsNotRunningToday(t *testing.T) {
	// A weekend-only trip is not cancelled on a Wednesday; it simply is not part
	// of today's plan, and saying otherwise would be a lie about a trip MOTIS
	// already knows does not run.
	index := gtfsRTIndexOf(t,
		[3]string{"KHH1:0:0600:W:0000011", "W:0000011", "0"},
	)
	entities, _, stats := buildGTFSRTCancellations(context.Background(), index, _gtfsRTWednesday,
		gtfsRTReader(map[string]*models.Bus_DailyTimetables{}))
	if len(entities) != 0 || stats.routesConsidered != 0 {
		t.Fatalf("emitted %v with stats %+v, want nothing considered", gtfsRTCancelledIDs(entities), stats)
	}
}

func TestBuildGTFSRTCancellationsSilencesAnUnreadableDeparture(t *testing.T) {
	// A daily departure we cannot parse cannot be matched to a scheduled one, so
	// it fails the gate rather than being skipped — skipping it would make the
	// trip it accounts for look cancelled.
	index := gtfsRTIndexOf(t,
		[3]string{"KHH1:0:0600:W:1111100", "W:1111100", "0"},
		[3]string{"KHH1:0:0630:W:1111100", "W:1111100", "0"},
	)
	daily := gtfsRTDaily("KHH1", 0, "06:00")
	daily.Direction[0].DailyTimetables = append(daily.Direction[0].DailyTimetables,
		&models.Bus_DailyTimetable{StopTimes: []*models.Bus_StopTime{
			{StopSequence: 1, DepartureTime: "not a time", StopUID: "S1"},
		}})
	entities, _, stats := buildGTFSRTCancellations(context.Background(), index, _gtfsRTWednesday,
		gtfsRTReader(map[string]*models.Bus_DailyTimetables{"KHH1": daily}))
	if len(entities) != 0 {
		t.Fatalf("emitted %v, want nothing", gtfsRTCancelledIDs(entities))
	}
	if stats.routesGateFailed != 1 {
		t.Errorf("routes_gate_failed = %d, want 1", stats.routesGateFailed)
	}
}

func TestMarshalGTFSRTFeedIsAFullDataset(t *testing.T) {
	payload, err := marshalGTFSRTFeed([]*gtfs.FeedEntity{cancelledTripEntity("KHH1:0:0600:W:1111100", "20260805")}, _gtfsRTWednesday)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	feed := &gtfs.FeedMessage{}
	if err := proto.Unmarshal(payload, feed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if feed.GetHeader().GetGtfsRealtimeVersion() != "2.0" {
		t.Errorf("version = %q, want 2.0", feed.GetHeader().GetGtfsRealtimeVersion())
	}
	if feed.GetHeader().GetIncrementality() != gtfs.FeedHeader_FULL_DATASET {
		t.Error("feed is not a full dataset; every rebuild replaces the whole feed")
	}
	if len(feed.GetEntity()) != 1 {
		t.Fatalf("entities = %d, want 1", len(feed.GetEntity()))
	}
}
