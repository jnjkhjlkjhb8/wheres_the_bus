package maas

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"github.com/pashagolub/pgxmock/v4"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// _plannerTestPlan is MOTIS answering with two itineraries: a bus-to-metro
// trip with one transfer, listed first, and a slower-looking direct metro
// ride that is in fact faster.
const _plannerTestPlan = `{"previousPageCursor":"earlier","nextPageCursor":"later","itineraries":[
 {"id":"itinerary-a","duration":2820,"startTime":"2027-01-01T07:58:00+08:00","endTime":"2027-01-01T08:45:00+08:00","transfers":1,"legs":[
  {"mode":"WALK","duration":120,"startTime":"2027-01-01T07:58:00+08:00","endTime":"2027-01-01T08:00:00+08:00",
   "from":{"name":"起點","lat":25.0,"lon":121.5},"to":{"name":"公館","stopId":"taiwan_TPE1","lat":25.01,"lon":121.53},
   "legGeometry":{"points":"_p~iF~ps|U","precision":5}},
  {"mode":"BUS","duration":1200,"startTime":"2027-01-01T08:00:00+08:00","endTime":"2027-01-01T08:20:00+08:00",
   "scheduledStartTime":"2027-01-01T08:00:00+08:00","scheduledEndTime":"2027-01-01T08:20:00+08:00","realTime":true,
   "tripId":"20270101_07:55_taiwan_TPE157462:0:0755:1111100","routeId":"taiwan_TPE15746",
   "routeShortName":"307","displayName":"307","headsign":"板橋","agencyId":"A1","agencyName":"首都客運",
   "from":{"name":"公館","stopId":"taiwan_TPE1","lat":25.01,"lon":121.53,"departure":"2027-01-01T08:00:00+08:00"},
   "to":{"name":"台電大樓","stopId":"taiwan_TPE3","lat":25.02,"lon":121.52,"arrival":"2027-01-01T08:20:00+08:00"},
   "intermediateStops":[{"name":"師大分部","stopId":"taiwan_TPE2","lat":25.015,"lon":121.525,"arrival":"2027-01-01T08:10:00+08:00","departure":"2027-01-01T08:10:30+08:00"}]},
  {"mode":"WALK","duration":120,"startTime":"2027-01-01T08:20:00+08:00","endTime":"2027-01-01T08:22:00+08:00",
   "from":{"name":"台電大樓","stopId":"taiwan_TPE3","lat":25.02,"lon":121.52},"to":{"name":"古亭","stopId":"taiwan_G09","lat":25.026,"lon":121.522}},
  {"mode":"SUBWAY","duration":900,"startTime":"2027-01-01T08:25:00+08:00","endTime":"2027-01-01T08:40:00+08:00",
   "tripId":"20270101_08:10_taiwan_M:TRTC:G:0:weekday","routeShortName":"G",
   "from":{"name":"古亭","stopId":"taiwan_G09","lat":25.026,"lon":121.522},"to":{"name":"台北車站","stopId":"taiwan_BL12","lat":25.046,"lon":121.517},
   "legGeometry":{"points":"_p~iF~ps|U_ulLnnqC_mqNvxq` + "`" + `@","precision":5}},
  {"mode":"WALK","duration":300,"startTime":"2027-01-01T08:40:00+08:00","endTime":"2027-01-01T08:45:00+08:00",
   "from":{"name":"台北車站","stopId":"taiwan_BL12","lat":25.046,"lon":121.517},"to":{"name":"終點","lat":25.05,"lon":121.52}}]},
 {"duration":2400,"startTime":"2027-01-01T08:10:00+08:00","endTime":"2027-01-01T08:50:00+08:00","transfers":0,"legs":[
  {"mode":"SUBWAY","duration":2400,"startTime":"2027-01-01T08:10:00+08:00","endTime":"2027-01-01T08:50:00+08:00",
   "tripId":"20270101_08:00_taiwan_M:TRTC:BL:0:weekday","routeShortName":"BL",
   "from":{"name":"公館","stopId":"taiwan_G07","lat":25.01,"lon":121.53},"to":{"name":"台北車站","stopId":"taiwan_BL12","lat":25.046,"lon":121.517},
   "legGeometry":{"points":"_p~iF~ps|U_ulLnnqC_mqNvxq` + "`" + `@","precision":5}}]}]}`

type recordingPlannerStream struct {
	grpc.ServerStreamingServer[pb.PlannerUpdate]
	ctx     context.Context
	sendErr error
	updates []*pb.PlannerUpdate
}

func (s *recordingPlannerStream) Context() context.Context { return s.ctx }

func (s *recordingPlannerStream) Send(update *pb.PlannerUpdate) error {
	// Snapshot: both sends carry itineraries mutated in between.
	s.updates = append(s.updates, proto.CloneOf(update))
	return s.sendErr
}

func plannerUpstream(t *testing.T, body string, status int) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(upstream.Close)
	return upstream, &hits
}

func newPlannerTestServer(t *testing.T, cache MaasCache, db maasDB, config maasSharedWorkConfig, upstreamURL string) *PlannerServer {
	t.Helper()
	config.Motis = NewMotisClient(upstreamURL)
	config.Motis.http.SetRetryCount(0)
	server := NewMaasServerWithCache(cache, db, config)
	t.Cleanup(server.Close)
	return NewPlannerServer(server, ratelimit.New(), DefaultMaasResourceConfig)
}

func plannerItineraryIDs(response *pb.PlannerResponse) string {
	ids := make([]string, 0, len(response.GetItineraries()))
	for _, itinerary := range response.GetItineraries() {
		id := itinerary.GetId()
		if strings.HasPrefix(id, "sha256:") {
			id = "hash"
		}
		ids = append(ids, id)
	}
	return strings.Join(ids, ",")
}

func TestPlannerStreamSendsRankedRoutesBeforeGeometry(t *testing.T) {
	upstream, hits := plannerUpstream(t, _plannerTestPlan, http.StatusOK)
	server := newPlannerTestServer(t, newControlledMaasCache(), nil, DefaultMaasSharedWorkConfig, upstream.URL)

	stream := &recordingPlannerStream{ctx: t.Context()}
	if err := server.PlanStream(&pb.PlannerRequest{}, stream); err != nil {
		t.Fatalf("PlanStream: %v", err)
	}
	if len(stream.updates) != 2 || stream.updates[0].Complete || !stream.updates[1].Complete {
		t.Fatalf("updates = %v, want routes then complete", stream.updates)
	}
	first, last := stream.updates[0].Plan, stream.updates[1].Plan
	if got := plannerItineraryIDs(first); got != "hash,itinerary-a" || plannerItineraryIDs(last) != got {
		t.Fatalf("order = %q then %q, want the faster direct ride first in both", got, plannerItineraryIDs(last))
	}
	if len(first.Itineraries[1].Legs[0].Path) != 0 {
		t.Fatal("the routes message must not carry geometry")
	}
	if len(last.Itineraries[1].Legs[0].Path) != 1 || len(last.Itineraries[1].Legs[3].Path) != 3 {
		t.Fatalf("complete message geometry = %v / %v", last.Itineraries[1].Legs[0].Path, last.Itineraries[1].Legs[3].Path)
	}
	if first.PreviousPageCursor != "earlier" || last.NextPageCursor != "later" {
		t.Fatalf("cursors = %q/%q", first.PreviousPageCursor, last.NextPageCursor)
	}
	if hits.Load() != 1 {
		t.Fatalf("upstream hits = %d", hits.Load())
	}
}

// The cache holds MOTIS's whole answer, so a different sort is an ordering of
// it, not a second plan.
func TestPlannerCacheHitAnswersAnySortInOneMessage(t *testing.T) {
	upstream, hits := plannerUpstream(t, _plannerTestPlan, http.StatusOK)
	server := newPlannerTestServer(t, newControlledMaasCache(), nil, DefaultMaasSharedWorkConfig, upstream.URL)
	if _, err := server.Plan(t.Context(), &pb.PlannerRequest{}); err != nil {
		t.Fatal(err)
	}
	stream := &recordingPlannerStream{ctx: t.Context()}
	req := &pb.PlannerRequest{Sort: pb.PlannerSort_PLANNER_SORT_LEAST_WALKING}
	if err := server.PlanStream(req, stream); err != nil {
		t.Fatal(err)
	}
	if len(stream.updates) != 1 || !stream.updates[0].Complete {
		t.Fatalf("cache hit updates = %v", stream.updates)
	}
	if got := plannerItineraryIDs(stream.updates[0].Plan); got != "hash,itinerary-a" {
		t.Fatalf("least walking order = %q", got)
	}
	if len(stream.updates[0].Plan.Itineraries[1].Legs[0].Path) == 0 {
		t.Fatal("a cache hit must carry geometry")
	}
	if hits.Load() != 1 {
		t.Fatalf("upstream hits = %d, want 1", hits.Load())
	}
}

func TestPlannerPlanRanksAndTrimsToTop(t *testing.T) {
	upstream, _ := plannerUpstream(t, _plannerTestPlan, http.StatusOK)
	server := newPlannerTestServer(t, newControlledMaasCache(), nil, DefaultMaasSharedWorkConfig, upstream.URL)
	got, err := server.Plan(t.Context(), &pb.PlannerRequest{Top: 1, Sort: pb.PlannerSort_PLANNER_SORT_FEWEST_TRANSFERS})
	if err != nil {
		t.Fatal(err)
	}
	if plannerItineraryIDs(got) != "hash" {
		t.Fatalf("top 1 fewest transfers = %q", plannerItineraryIDs(got))
	}
}

// The buffer arrives in minutes and comes back out of the walk in seconds.
func TestPlannerTakesTheRequestedBufferOutOfTheWalk(t *testing.T) {
	upstream, _ := plannerUpstream(t, _plannerTestPlan, http.StatusOK)
	server := newPlannerTestServer(t, newControlledMaasCache(), nil, DefaultMaasSharedWorkConfig, upstream.URL)
	got, err := server.Plan(t.Context(), &pb.PlannerRequest{TransferBufferMinutes: 1})
	if err != nil {
		t.Fatal(err)
	}
	transfer := got.Itineraries[1]
	if transfer.WalkSeconds != 480 || transfer.Transfers[0].MarginSeconds != 240 {
		t.Fatalf("walk = %d, margin = %d, want 480 and 240", transfer.WalkSeconds, transfer.Transfers[0].MarginSeconds)
	}
}

func TestPlannerRejectsWorkItCannotStart(t *testing.T) {
	upstream, hits := plannerUpstream(t, `{}`, http.StatusNotFound)
	server := newPlannerTestServer(t, newControlledMaasCache(), nil, maasSharedWorkConfig{MaxConcurrent: 1}, upstream.URL)

	atCap := &pb.PlannerRequest{TransitModes: make([]pb.PlannerTransitMode, maxTransitModes)}
	if _, err := server.Plan(t.Context(), atCap); status.Code(err) != codes.NotFound {
		t.Fatalf("modes at cap code = %v, want the upstream's NotFound", status.Code(err))
	}
	overCap := &pb.PlannerRequest{TransitModes: make([]pb.PlannerTransitMode, maxTransitModes+1)}
	if _, err := server.Plan(t.Context(), overCap); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("modes over cap code = %v", status.Code(err))
	}

	release, err := server.maas.acquireWorkSlot()
	if err != nil {
		t.Fatal(err)
	}
	stream := &recordingPlannerStream{ctx: t.Context()}
	if err := server.PlanStream(&pb.PlannerRequest{}, stream); status.Code(err) != codes.ResourceExhausted || len(stream.updates) != 0 {
		t.Fatalf("no slot: error=%v updates=%v", err, stream.updates)
	}
	release()

	server.maas.Close()
	if _, err := server.Plan(t.Context(), &pb.PlannerRequest{}); status.Code(err) != codes.Unavailable {
		t.Fatalf("closing code = %v", status.Code(err))
	}
	if hits.Load() != 1 {
		t.Fatalf("upstream hits = %d, want only the at-cap request", hits.Load())
	}
}

func TestPlannerCallerHangUpCancelsTheWork(t *testing.T) {
	started := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer upstream.Close()
	server := newPlannerTestServer(t, newControlledMaasCache(), nil, maasSharedWorkConfig{MaxConcurrent: 1, Timeout: 10 * time.Second}, upstream.URL)
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		_, err := server.Plan(ctx, &pb.PlannerRequest{})
		done <- err
	}()
	awaitMaasEvent(t, started, "upstream request")
	cancel()
	select {
	case err := <-done:
		if status.Code(err) != codes.Canceled {
			t.Fatalf("hang-up code = %v (%v)", status.Code(err), err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a caller hanging up did not end its work")
	}
}

func TestPlannerFreshStopsBeforeUpstreamAndBeforeCaching(t *testing.T) {
	upstream, hits := plannerUpstream(t, _plannerTestPlan, http.StatusOK)
	cache := newControlledMaasCache()
	server := newPlannerTestServer(t, cache, nil, DefaultMaasSharedWorkConfig, upstream.URL)
	noop := func(*pb.PlannerResponse) error { return nil }
	charged := 0
	charge := func() error { charged++; return nil }

	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := server.slotted(cancelled, &pb.PlannerRequest{}, charge, noop); status.Code(err) != codes.Canceled {
		t.Fatalf("cancelled miss error=%v", err)
	}
	// The deadline has passed but the context's timer has not recorded it.
	expired := pendingDeadlineContext{Context: t.Context(), deadline: time.Now().Add(-time.Second)}
	if _, err := server.slotted(expired, &pb.PlannerRequest{}, charge, noop); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("expired miss error=%v", err)
	}
	if hits.Load() != 0 || charged != 0 {
		t.Fatalf("ended work reached upstream %d times, charged %d", hits.Load(), charged)
	}

	gone := errors.New("client gone")
	stream := &recordingPlannerStream{ctx: t.Context(), sendErr: gone}
	if err := server.PlanStream(&pb.PlannerRequest{}, stream); !errors.Is(err, gone) {
		t.Fatalf("send failure = %v", err)
	}
	if len(stream.updates) != 1 || cache.setCalls.Load() != 0 {
		t.Fatalf("after a failed send: updates=%d, cache sets=%d", len(stream.updates), cache.setCalls.Load())
	}
}

// The second contract must see the same priced, identified legs the first
// one would, and the estimated bus hop flags its transfer's times.
func TestPlannerCarriesFaresIdentitiesAndEstimatedHops(t *testing.T) {
	upstream, _ := plannerUpstream(t, _plannerTestPlan, http.StatusOK)
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery("bus_subroutes").
		WithArgs([]int32{1}, []string{"公館"}, []string{"台電大樓"}, []string{"307"}, []string{"307"}, []string{"307"}).
		WillReturnRows(
			pgxmock.NewRows([]string{"index", "route", "direction", "departure", "arrival", "count"}).
				AddRow(int32(1), "TPE157462", int32(0), "TPE1", "TPE3", int64(1))).RowsWillBeClosed()
	db.ExpectQuery("mrt_journey_matrix").
		WithArgs([]int32{3, 5}, []string{"subway", "subway"}, []string{"古亭", "公館"}, []string{"台北車站", "台北車站"}).
		WillReturnRows(
			pgxmock.NewRows([]string{"index", "fare"}).AddRow(int32(3), int32(25)).AddRow(int32(5), int32(20))).RowsWillBeClosed()
	db.ExpectQuery("bus_segment_time").
		WithArgs([]int32{0}, []string{"TPE157462"}, []int32{0}, []string{"TPE1"}, []string{"TPE3"}).
		WillReturnRows(pgxmock.NewRows([]string{"leg_index"}).AddRow(int32(0))).RowsWillBeClosed()
	server := newPlannerTestServer(t, newControlledMaasCache(), db, DefaultMaasSharedWorkConfig, upstream.URL)

	got, err := server.Plan(t.Context(), &pb.PlannerRequest{Sort: pb.PlannerSort_PLANNER_SORT_CHEAPEST})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
	direct, transfer := got.Itineraries[0], got.Itineraries[1]
	if !direct.FareComplete || direct.TotalFare != 20 || transfer.FareComplete || transfer.TotalFare != 25 {
		t.Fatalf("fares direct=%d/%v transfer=%d/%v", direct.TotalFare, direct.FareComplete, transfer.TotalFare, transfer.FareComplete)
	}
	if !transfer.Legs[1].NotificationIdentity.GetSupported() || transfer.Legs[3].Fare != 25 {
		t.Fatalf("bus identity=%v, metro fare=%d", transfer.Legs[1].NotificationIdentity, transfer.Legs[3].Fare)
	}
	want := &pb.PlannerTransfer{FromLeg: 1, ToLeg: 3, MarginSeconds: 180, Level: pb.TransferLevel_TRANSFER_LEVEL_COMFORTABLE, TimesEstimated: true}
	if len(transfer.Transfers) != 1 || !proto.Equal(transfer.Transfers[0], want) {
		t.Fatalf("transfers = %v, want %v", transfer.Transfers, want)
	}
}

func TestPlannerQueryAdaptsEveryOption(t *testing.T) {
	at := time.Date(2027, 1, 1, 8, 30, 15, 0, time.Local)
	maxTransfers := int32(2)
	req := &pb.PlannerRequest{
		From: &pb.Location{Lat: 25, Lng: 121.5}, To: &pb.Location{Lat: 25.1, Lng: 121.6},
		Time: timestamppb.New(at), ArriveBy: true, Top: 3,
		TransitModes: []pb.PlannerTransitMode{
			pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_HIGH_SPEED_RAIL, pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_RAIL,
			pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS, pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_COACH,
			pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_SUBWAY, pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_TRAM,
			pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_FERRY, pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_CABLE_CAR,
		},
		TransferBufferMinutes: 61,
		FirstMileMode:         pb.PlannerAccessMode_PLANNER_ACCESS_MODE_BIKE, FirstMileMinutes: 20,
		LastMileMode: pb.PlannerAccessMode_PLANNER_ACCESS_MODE_SHARED_BIKE, LastMileMinutes: 15,
		Wheelchair: true, WalkSpeedCmPerSec: 90, MaxTransfers: &maxTransfers,
		AvoidReservation: true, CarryBike: true, PageCursor: "next", LegAlternatives: 2,
	}
	got := plannerQuery(req, time.Time{})
	want := url.Values{
		"fromPlace": {"25.000000,121.500000"}, "toPlace": {"25.100000,121.600000"},
		"time": {at.Format(time.RFC3339)}, "arriveBy": {"true"}, "numItineraries": {"8"},
		"transitModes":    {"HIGHSPEED_RAIL,REGIONAL_RAIL,BUS,COACH,SUBWAY,TRAM,FERRY,AERIAL_LIFT"},
		"minTransferTime": {"0"}, "additionalTransferTime": {"60"},
		"preTransitModes": {"BIKE"}, "maxPreTransitTime": {"1200"},
		"postTransitModes": {"RENTAL,WALK"}, "maxPostTransitTime": {"900"}, "postTransitRentalFormFactors": {"BICYCLE"},
		"pedestrianProfile": {"WHEELCHAIR"}, "pedestrianSpeed": {"0.90"}, "maxTransfers": {"2"},
		"noCompulsoryReservation": {"true"}, "requireBikeTransport": {"true"},
		"pageCursor": {"next"}, "timetableView": {"true"}, "numLegAlternatives": {"2"},
	}
	if got.Encode() != want.Encode() {
		t.Fatalf("query\n got %s\nwant %s", got.Encode(), want.Encode())
	}
}

func TestPlannerQueryDefaultsToNowAndMotisTransferTimes(t *testing.T) {
	now := time.Date(2027, 1, 1, 9, 0, 0, 0, time.Local)
	got := plannerQuery(&pb.PlannerRequest{
		FirstMileMode: pb.PlannerAccessMode_PLANNER_ACCESS_MODE_CAR,
		LastMileMode:  pb.PlannerAccessMode_PLANNER_ACCESS_MODE_WALK,
	}, now)
	for key, want := range map[string]string{
		"time": now.Format(time.RFC3339), "minTransferTime": "0", "additionalTransferTime": "0", "numItineraries": "10",
		"preTransitModes": "CAR", "postTransitModes": "WALK", "transitModes": "",
	} {
		if got.Get(key) != want {
			t.Errorf("%s = %q, want %q", key, got.Get(key), want)
		}
	}
}

func TestPlannerKeyIgnoresOnlyTheSort(t *testing.T) {
	base := &pb.PlannerRequest{From: &pb.Location{Lat: 25}, Top: 3}
	sorted := proto.CloneOf(base)
	sorted.Sort = pb.PlannerSort_PLANNER_SORT_CHEAPEST
	wheelchair := proto.CloneOf(base)
	wheelchair.Wheelchair = true
	key := plannerKey(base)
	if !strings.HasPrefix(key, "planner:plan:v1:") || len(key) != len("planner:plan:v1:")+32 {
		t.Fatalf("key = %q", key)
	}
	if plannerKey(sorted) != key || plannerKey(wheelchair) == key {
		t.Fatal("the key must ignore the sort and nothing else")
	}
	if sorted.Sort != pb.PlannerSort_PLANNER_SORT_CHEAPEST {
		t.Fatal("plannerKey changed its caller's request")
	}
}

// One caller, one planner allowance, whichever contract spends it. The
// planner spends it only when it has to ask MOTIS: a sort change, answered
// from cache, is free.
func TestPlannerChargesTheSharedQuotaOnlyOnACacheMiss(t *testing.T) {
	upstream, hits := plannerUpstream(t, _plannerTestPlan, http.StatusOK)
	rl := ratelimit.New()
	config := MaasResourceConfig{RateLimit: 2, RateWindow: time.Minute}
	maas := newMotisTestServer(newControlledMaasCache(), DefaultMaasSharedWorkConfig, upstream.URL)
	t.Cleanup(maas.Close)
	server := NewPlannerServer(maas, rl, config)
	ctx := limiterContext("203.0.113.79:5555")

	for _, sort := range []pb.PlannerSort{pb.PlannerSort_PLANNER_SORT_FASTEST, pb.PlannerSort_PLANNER_SORT_CHEAPEST, pb.PlannerSort_PLANNER_SORT_LEAST_WALKING} {
		if _, err := server.Plan(ctx, &pb.PlannerRequest{Sort: sort}); err != nil {
			t.Fatalf("sort %v: %v", sort, err)
		}
	}
	unary := MaasResourceInterceptor(rl, config)
	planned := false
	ok := func(context.Context, any) (any, error) { planned = true; return nil, nil }
	if _, err := unary(ctx, nil, &grpc.UnaryServerInfo{FullMethod: pb.PlannerService_Plan_FullMethodName}, ok); err != nil || !planned {
		t.Fatalf("the interceptor charged PlannerService: %v", err)
	}
	if _, err := unary(ctx, nil, &grpc.UnaryServerInfo{FullMethod: pb.MaasService_Plan_FullMethodName}, ok); err != nil {
		t.Fatalf("MaasService within the quota the planner left: %v", err)
	}
	stream := &recordingPlannerStream{ctx: ctx}
	if err := server.PlanStream(&pb.PlannerRequest{Top: 2}, stream); status.Code(err) != codes.ResourceExhausted || len(stream.updates) != 0 {
		t.Fatalf("miss after MaasService spent the quota: error=%v updates=%d", err, len(stream.updates))
	}
	if hits.Load() != 1 {
		t.Fatalf("upstream hits = %d, want 1", hits.Load())
	}
}
