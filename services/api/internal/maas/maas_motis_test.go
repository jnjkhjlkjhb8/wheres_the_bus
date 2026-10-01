package maas

import (
	"math"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/protobuf/proto"
)

func TestConvertMotisItinerariesPairsGeometryWithSectionsByIndex(t *testing.T) {
	api, geometry := convertMotisItineraries([]motisItinerary{
		{
			Duration: 600,
			Legs: []motisLeg{
				{Mode: "WALK", LegGeometry: motisPolyline{Points: "_p~iF~ps|U", Precision: 5}},
				{Mode: "BUS", RouteShortName: "307"},
			},
		},
		{
			Duration: 900,
			Legs: []motisLeg{
				{Mode: "SUBWAY", RouteShortName: "BL"},
			},
		},
	})

	_, refs := convertRoutes(t.Context(), nil, api)
	if len(refs) != 3 {
		t.Fatalf("refs = %d, want 3", len(refs))
	}
	if len(geometry) != len(refs) {
		t.Fatalf("geometry = %d, refs = %d; they must be parallel", len(geometry), len(refs))
	}
	if geometry[0] == nil {
		t.Error("geometry[0] = nil, want the walk leg's path")
	}
	if geometry[1] != nil || geometry[2] != nil {
		t.Error("transit legs must carry no walk geometry")
	}
	if !applyMotisWalkGeometry(refs, geometry) {
		t.Fatal("applyMotisWalkGeometry reported a mismatch")
	}
	if len(refs[0].target.WalkPath) == 0 {
		t.Error("walk section got no path")
	}
	if len(refs[1].target.WalkPath) != 0 {
		t.Error("transit section got a walk path")
	}
}

// A mismatch must be refused rather than zipped, for the same reason: a wrong
// path is worse than no path, because the app already renders a straight line
// when a section has none.
func TestApplyMotisWalkGeometryRefusesLengthMismatch(t *testing.T) {
	refs := []maasSectionRef{{target: &pb.Section{}}, {target: &pb.Section{}}}
	if applyMotisWalkGeometry(refs, []*motisWalkGeometry{{path: []*pb.Location{{Lat: 1, Lng: 2}}}}) {
		t.Fatal("applyMotisWalkGeometry accepted a short geometry slice")
	}
	if len(refs[0].target.WalkPath) != 0 {
		t.Error("a refused apply must leave the sections untouched")
	}
}

func TestMotisTransitModeSeparatesHighSpeedFromRegionalRail(t *testing.T) {
	tests := []struct {
		motis string
		want  string
	}{
		{motis: "HIGHSPEED_RAIL", want: "THSR"},
		{motis: "REGIONAL_RAIL", want: "Rail"},
		{motis: "LONG_DISTANCE", want: "Rail"},
		{motis: "SUBWAY", want: "Subway"},
		{motis: "TRAM", want: "Tram"},
		{motis: "BUS", want: "Bus"},
		{motis: "COACH", want: "HighwayBus"},
		{motis: "AERIAL_LIFT", want: "CableCar"},
		{motis: "WALK", want: ""},
		{motis: "RENTAL", want: ""},
	}
	for _, tt := range tests {
		if got := motisTransitMode(tt.motis); got != tt.want {
			t.Errorf("motisTransitMode(%q) = %q, want %q", tt.motis, got, tt.want)
		}
	}
	// The classifiers the rest of the router switches on must agree.
	if !isThsrMode(motisTransitMode("HIGHSPEED_RAIL")) {
		t.Error("HIGHSPEED_RAIL is not classified as THSR")
	}
	if !isRailMode(motisTransitMode("REGIONAL_RAIL")) {
		t.Error("REGIONAL_RAIL is not classified as rail")
	}
	if isThsrMode(motisTransitMode("REGIONAL_RAIL")) {
		t.Error("REGIONAL_RAIL is classified as THSR")
	}
}

// Deselecting a mode must not be able to come back through a broader MOTIS
// alias: RAIL would reintroduce SUBWAY and HIGHSPEED_RAIL, silently unfiltering
// the search.
func TestMotisTransitModesAreExactNotBroadened(t *testing.T) {
	got := motisTransitModes([]int32{4})
	if len(got) != 1 || got[0] != "REGIONAL_RAIL" {
		t.Fatalf("TRA only = %q, want [REGIONAL_RAIL]", got)
	}
	all := motisTransitModes([]int32{3, 4, 5, 6, 7, 8, 9})
	for _, mode := range all {
		if mode == "RAIL" || mode == "TRANSIT" {
			t.Errorf("mode set contains the umbrella %q", mode)
		}
	}
	// Unknown ids contribute nothing rather than defaulting to everything.
	if got := motisTransitModes([]int32{42}); len(got) != 0 {
		t.Errorf("unknown id produced %q", got)
	}
}

// The precision comes from the response because MOTIS documents 7 for v1 and 6
// for v2 endpoints: a hardcoded exponent misplaces every point by a power of
// ten the day an endpoint's version moves.
func TestDecodeMotisPolylineHonoursResponsePrecision(t *testing.T) {
	const encoded = "_p~iF~ps|U_ulLnnqC"
	five := decodeMotisPolyline(motisPolyline{Points: encoded, Precision: 5})
	if len(five) != 2 {
		t.Fatalf("points = %d, want 2", len(five))
	}
	if math.Abs(five[0].Lat-38.5) > 1e-6 || math.Abs(five[0].Lng-(-120.2)) > 1e-6 {
		t.Errorf("first point = %v,%v want 38.5,-120.2", five[0].Lat, five[0].Lng)
	}
	six := decodeMotisPolyline(motisPolyline{Points: encoded, Precision: 6})
	if math.Abs(six[0].Lat-3.85) > 1e-6 {
		t.Errorf("precision 6 first lat = %v, want 3.85", six[0].Lat)
	}
	if decodeMotisPolyline(motisPolyline{Points: encoded, Precision: 0}) != nil {
		t.Error("a missing precision must decode to nothing, not to a guess")
	}
	if decodeMotisPolyline(motisPolyline{}) != nil {
		t.Error("an empty polyline must decode to nothing")
	}
}

// gc is the app's 省錢/省時 slider. MOTIS cannot search on price at all, so this
// ranking is the only thing that still makes the slider do something.
func TestRankMotisRoutesWeighsFareAgainstTimeAndTrims(t *testing.T) {
	build := func() *pb.MaasPlanResponse {
		return &pb.MaasPlanResponse{Routes: []*pb.Route{
			{TravelTime: 1800, TotalFare: 120}, // fast, dear
			{TravelTime: 3600, TotalFare: 30},  // slow, cheap
			{TravelTime: 2700, TotalFare: 75},  // between
		}}
	}

	cheapest := build()
	rankMotisRoutes(cheapest, 0, 3)
	if cheapest.Routes[0].TotalFare != 30 {
		t.Errorf("gc=0 put fare %d first, want the cheapest", cheapest.Routes[0].TotalFare)
	}

	fastest := build()
	rankMotisRoutes(fastest, 1, 3)
	if fastest.Routes[0].TravelTime != 1800 {
		t.Errorf("gc=1 put %ds first, want the fastest", fastest.Routes[0].TravelTime)
	}

	trimmed := build()
	rankMotisRoutes(trimmed, 1, 2)
	if len(trimmed.Routes) != 2 {
		t.Errorf("routes = %d, want the requested 2", len(trimmed.Routes))
	}

	// Every itinerary agreeing on an axis must not divide by a zero span.
	flat := &pb.MaasPlanResponse{Routes: []*pb.Route{
		{TravelTime: 600, TotalFare: 20},
		{TravelTime: 600, TotalFare: 20},
	}}
	rankMotisRoutes(flat, 0.5, 5)
	if len(flat.Routes) != 2 {
		t.Errorf("routes = %d, want both kept", len(flat.Routes))
	}
}

// MOTIS takes one instant, not TDX's depart/arrival pair, and does not reject a
// time in the past -- so unlike maasTimeParam there is no bump. A malformed
// clock falls back to now rather than failing a search the rider did ask for.
func TestMotisPlanQueryBuildsTheDocumentedShape(t *testing.T) {
	now := time.Date(2026, 8, 17, 9, 0, 0, 0, time.Local)
	query := motisPlanQuery(&pb.MaasPlanRequest{
		FromLat: 25.0478, FromLon: 121.5170,
		ToLat: 25.0330, ToLon: 121.5654,
		Date: "2026-08-18", Time: "08:30",
		Top:          3,
		TransitModes: []int32{5, 6},
		LastMileMode: 3,
	}, now)

	if got := query.Get("fromPlace"); got != "25.047800,121.517000" {
		t.Errorf("fromPlace = %q", got)
	}
	if got := query.Get("transitModes"); got != "BUS,COACH,SUBWAY" {
		t.Errorf("transitModes = %q", got)
	}
	// Wider than the rider asked for, so the ranking has alternatives to weigh.
	if got := query.Get("numItineraries"); got != "8" {
		t.Errorf("numItineraries = %q, want 8 (top 3 + 5)", got)
	}
	if got := query.Get("postTransitModes"); got != "RENTAL,WALK" {
		t.Errorf("postTransitModes = %q", got)
	}
	// Without the form factor a GBFS feed's scooters answer a request for 共享單車.
	if got := query.Get("postTransitRentalFormFactors"); got != "BICYCLE" {
		t.Errorf("postTransitRentalFormFactors = %q", got)
	}
	if query.Has("arriveBy") {
		t.Error("arriveBy must be absent on a departure search")
	}

	bad := motisPlanQuery(&pb.MaasPlanRequest{Date: "not-a-date", Time: "??"}, now)
	if got := bad.Get("time"); got != now.Format(time.RFC3339) {
		t.Errorf("malformed clock = %q, want now", got)
	}
}

// The MOTIS-only preferences. Each is omitted when unset rather than sent at a
// default, so MOTIS's own documented defaults stay the single source for them.
func TestMotisPlanQueryOmitsUnsetPreferences(t *testing.T) {
	now := time.Date(2026, 8, 17, 9, 0, 0, 0, time.Local)
	bare := motisPlanQuery(&pb.MaasPlanRequest{Date: "2026-08-18", Time: "08:30"}, now)
	for _, key := range []string{
		"pedestrianProfile", "pedestrianSpeed", "maxTransfers",
		"noCompulsoryReservation", "requireBikeTransport",
		"pageCursor", "timetableView", "numLegAlternatives",
	} {
		if bare.Has(key) {
			t.Errorf("%s was sent on a request that did not ask for it", key)
		}
	}
}

// maxTransfers=0 means "direct connections only", which is why the proto field
// carries presence: without it, a rider asking for no interchanges would be
// indistinguishable from a rider who never touched the control.
func TestMotisPlanQuerySendsZeroMaxTransfersWhenItWasAsked(t *testing.T) {
	now := time.Date(2026, 8, 17, 9, 0, 0, 0, time.Local)

	unset := motisPlanQuery(&pb.MaasPlanRequest{Date: "2026-08-18", Time: "08:30"}, now)
	if unset.Has("maxTransfers") {
		t.Error("an untouched control sent a transfer cap")
	}

	direct := motisPlanQuery(&pb.MaasPlanRequest{
		Date: "2026-08-18", Time: "08:30", MaxTransfers: proto.Int32(0),
	}, now)
	if got := direct.Get("maxTransfers"); got != "0" {
		t.Errorf("maxTransfers = %q, want 0 (direct only)", got)
	}
}

func TestMotisPlanQuerySendsThePreferencesItWasGiven(t *testing.T) {
	now := time.Date(2026, 8, 17, 9, 0, 0, 0, time.Local)
	query := motisPlanQuery(&pb.MaasPlanRequest{
		Date: "2026-08-18", Time: "08:30",
		Wheelchair:        true,
		WalkSpeedCmPerSec: 90,
		AvoidReservation:  true,
		CarryBike:         true,
		PageCursor:        "later:42",
		LegAlternatives:   3,
	}, now)

	if got := query.Get("pedestrianProfile"); got != "WHEELCHAIR" {
		t.Errorf("pedestrianProfile = %q", got)
	}
	// Centimetres on the wire, metres per second to MOTIS.
	if got := query.Get("pedestrianSpeed"); got != "0.90" {
		t.Errorf("pedestrianSpeed = %q, want 0.90", got)
	}
	if query.Get("noCompulsoryReservation") != "true" || query.Get("requireBikeTransport") != "true" {
		t.Errorf("reservation/bike flags = %q %q",
			query.Get("noCompulsoryReservation"), query.Get("requireBikeTransport"))
	}
	if got := query.Get("pageCursor"); got != "later:42" {
		t.Errorf("pageCursor = %q", got)
	}
	// A cursor into a single departure window has nothing to advance through,
	// so paging implies the timetable view.
	if query.Get("timetableView") != "true" {
		t.Error("a cursor was sent without the timetable view that gives it meaning")
	}
	if got := query.Get("numLegAlternatives"); got != "3" {
		t.Errorf("numLegAlternatives = %q", got)
	}
}

func TestMotisSectionKeepsOnlyTheTransitLegOfEachAlternative(t *testing.T) {
	section := motisSection(motisLeg{
		Mode:           "BUS",
		RouteShortName: "307",
		Alternatives: [][]motisLeg{
			{
				{Mode: "WALK"},
				{Mode: "BUS", RouteShortName: "310", StartTime: "2026-08-18T07:14:00Z"},
				{Mode: "WALK"},
			},
			// Interlined: several transit legs, one service being named.
			{
				{Mode: "WALK"},
				{Mode: "SUBWAY", RouteShortName: "BL"},
				{Mode: "SUBWAY", RouteShortName: "BL"},
				{Mode: "WALK"},
			},
			{{Mode: "WALK"}, {Mode: "WALK"}},
		},
	})

	if got := len(section.Alternatives); got != 2 {
		t.Fatalf("alternatives = %d, want 2 (the walk-only one is dropped)", got)
	}
	if got := section.Alternatives[0].Transport.Number; got != "310" {
		t.Errorf("first alternative route = %q, want 310", got)
	}
	// Local, like every other timestamp the section carries.
	wantDeparture := mustParseRFC3339(t, "2026-08-18T07:14:00Z").In(time.Local).Format(time.RFC3339)
	if got := section.Alternatives[0].Departure.Time; got != wantDeparture {
		t.Errorf("first alternative departure = %q, want %q", got, wantDeparture)
	}
	if got := section.Alternatives[1].Transport.Number; got != "BL" {
		t.Errorf("interlined alternative route = %q, want BL", got)
	}
	// Nothing nests: an alternative is a leaf, or the app has to recurse.
	for i, alt := range section.Alternatives {
		if len(alt.Alternatives) != 0 {
			t.Errorf("alternative %d carries its own alternatives", i)
		}
	}
}

func TestConvertMotisItinerariesRestatesUTCInLocalTime(t *testing.T) {
	api, _ := convertMotisItineraries([]motisItinerary{{
		StartTime: "2026-08-30T22:16:00Z",
		EndTime:   "2026-08-30T23:08:00Z",
		Legs: []motisLeg{{
			Mode:      "BUS",
			StartTime: "2026-08-30T22:22:00Z",
			EndTime:   "2026-08-30T22:32:00Z",
			IntermediateStops: []motisPlace{{
				Departure: "2026-08-30T22:27:00Z",
			}},
		}},
	}})

	// The app reads these as wall-clock text, so every one of them has to be
	// the rider's clock: in Taipei 22:16Z is 06:16 the next morning.
	route := api.Data.Routes[0]
	section := route.Sections[0]
	for name, pair := range map[string][2]string{
		"route start":       {route.StartTime, "2026-08-30T22:16:00Z"},
		"route end":         {route.EndTime, "2026-08-30T23:08:00Z"},
		"departure":         {section.Departure.Time, "2026-08-30T22:22:00Z"},
		"arrival":           {section.Arrival.Time, "2026-08-30T22:32:00Z"},
		"intermediate stop": {section.IntermediateStops[0].Departure.Time, "2026-08-30T22:27:00Z"},
	} {
		want := mustParseRFC3339(t, pair[1]).In(time.Local)
		got := mustParseRFC3339(t, pair[0])
		if !got.Equal(want) {
			t.Fatalf("%s moved in time: %q", name, pair[0])
		}
		if pair[0] != want.Format(time.RFC3339) {
			t.Fatalf("%s not in the router's zone: %q, want %q", name, pair[0], want.Format(time.RFC3339))
		}
	}
}

func mustParseRFC3339(t *testing.T, ts string) time.Time {
	t.Helper()
	parsed, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		t.Fatalf("unparseable timestamp %q: %v", ts, err)
	}
	return parsed
}
