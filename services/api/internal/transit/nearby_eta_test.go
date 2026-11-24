package transit

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// nearbyEtaSource serves fixed payloads by key and records demand touches.
type nearbyEtaSource struct {
	mu       sync.Mutex
	payloads map[string][]byte
	touched  []string
	ttl      time.Duration
}

func (s *nearbyEtaSource) Get(_ context.Context, key string) ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.payloads[key]
	return v, ok
}
func (*nearbyEtaSource) ScanKeys(context.Context, string) []string { return nil }
func (*nearbyEtaSource) Subscribe(context.Context, string) (<-chan []byte, func(), error) {
	return nil, nil, errors.New("etas polls, it never subscribes")
}
func (s *nearbyEtaSource) Touch(_ context.Context, key string, ttl time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.touched = append(s.touched, key)
	s.ttl = ttl
}

func (s *nearbyEtaSource) set(t *testing.T, city, group string, arrival *pb.Bus_StationArrival) {
	t.Helper()
	data, err := proto.Marshal(arrival)
	if err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.payloads[shared.BusStationEtaKey(city, group)] = data
}

func etaRoute(uid string, estimate int32) *pb.Bus_StopEstimate {
	return &pb.Bus_StopEstimate{SubRouteUid: uid, Estimate: estimate, Buses: []*pb.BusPosition{{PlateNumb: "KKA-1"}}}
}

func TestNearbyEtaGroupsSkipIncompleteAndCapAtTen(t *testing.T) {
	asked := []*pb.Bus_Ask_StationGroup{{City: "Taipei"}, {GroupUid: "G"}}
	for range 12 {
		asked = append(asked, &pb.Bus_Ask_StationGroup{City: "Taipei", GroupUid: "G"})
	}
	if got := nearbyEtaGroups(asked); len(got) != 10 {
		t.Fatalf("groups = %d, want the first 10 complete ones", len(got))
	}
	err := streamNearbyEtas(t.Context(), &nearbyEtaSource{}, asked[:2], time.Hour, nil)
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("incomplete groups error = %v", err)
	}
	stream := &transitTestStream[*pb.Resp_BusStationEtas]{ctx: t.Context(), t: t}
	if err := (&BusStationserver{}).Etas(&pb.Bus_Ask_StationGroups{}, stream); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("empty request error = %v", err)
	}
}

func TestSoonestNearbyRoutesKeepsThreeTimedWithoutVehicles(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	routes := []*pb.Bus_StopEstimate{
		{SubRouteUid: "unix-300", ArrivalUnix: now.Unix() + 300, Estimate: 9},
		etaRoute("est-120", 120),
		{SubRouteUid: "not-departed", Estimate: -1, StopStatus: 1},
		{SubRouteUid: "last-passed", StopStatus: 3},
		{SubRouteUid: "arriving", StopStatus: 0},
		{SubRouteUid: "unix-past", ArrivalUnix: now.Unix() - 30},
		etaRoute("est-900", 900),
	}
	got := soonestNearbyRoutes(routes, now)
	want := []string{"arriving", "unix-past", "est-120"}
	if len(got) != len(want) {
		t.Fatalf("routes = %v, want %v", got, want)
	}
	for i, r := range got {
		if r.SubRouteUid != want[i] || r.Buses != nil {
			t.Fatalf("route %d = %v, want %s without vehicles", i, r, want[i])
		}
	}
}

func TestPollNearbyEtasSendsOnlyChangedFrames(t *testing.T) {
	src := &nearbyEtaSource{payloads: map[string][]byte{
		shared.BusStationEtaKey("Taipei", "empty"):   {},
		shared.BusStationEtaKey("Taipei", "garbage"): {0xff, 0xff},
	}}
	src.set(t, "Taipei", "A", &pb.Bus_StationArrival{StationName: "A", Routes: []*pb.Bus_StopEstimate{etaRoute("307", 120)}})
	groups := []*pb.Bus_Ask_StationGroup{
		{City: "Taipei", GroupUid: "A"}, {City: "Taipei", GroupUid: "missing"},
		{City: "Taipei", GroupUid: "empty"}, {City: "Taipei", GroupUid: "garbage"},
		{City: "NewTaipei", GroupUid: "B"},
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	poll := make(chan time.Time)
	frames := make(chan *pb.Resp_BusStationEtas, 4)
	done := make(chan error, 1)
	go func() {
		done <- pollNearbyEtas(ctx, src, groups, poll, func(f *pb.Resp_BusStationEtas) error {
			frames <- f
			return nil
		})
	}()

	first := <-frames
	if len(first.Groups) != 1 || first.Groups["A"].Routes[0].SubRouteUid != "307" || first.Groups["A"].Routes[0].Buses != nil {
		t.Fatalf("first frame = %v, want only A's trimmed routes", first)
	}
	poll <- time.Now()
	src.set(t, "NewTaipei", "B", &pb.Bus_StationArrival{StationName: "B"})
	poll <- time.Now()
	if second := <-frames; len(second.Groups) != 2 {
		t.Fatalf("second frame = %v, want A and B", second)
	}
	poll <- time.Now()
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("poll ended with %v", err)
	}
	if len(frames) != 0 {
		t.Fatalf("an unchanged poll sent %d frames", len(frames))
	}
	src.mu.Lock()
	defer src.mu.Unlock()
	// One touch per distinct city on each of the four polls.
	if len(src.touched) != 8 || src.touched[0] != busEtaDemandKey("Taipei") || src.touched[1] != busEtaDemandKey("NewTaipei") || src.ttl != 10*time.Minute {
		t.Fatalf("demand touches = %v ttl %v", src.touched, src.ttl)
	}
}

func TestStreamNearbyEtasReturnsSendFailure(t *testing.T) {
	sendErr := errors.New("client gone")
	src := &nearbyEtaSource{payloads: map[string][]byte{}}
	src.set(t, "Taipei", "A", &pb.Bus_StationArrival{StationName: "A"})
	err := streamNearbyEtas(t.Context(), src, []*pb.Bus_Ask_StationGroup{{City: "Taipei", GroupUid: "A"}}, time.Hour,
		func(*pb.Resp_BusStationEtas) error { return sendErr })
	if !errors.Is(err, sendErr) {
		t.Fatalf("stream error = %v, want the send failure", err)
	}
}

func TestNearbyEtaRemainingAtTheEdges(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	tests := []struct {
		name  string
		route *pb.Bus_StopEstimate
		want  int64
	}{
		{name: "any arrival instant wins over the estimate", route: &pb.Bus_StopEstimate{ArrivalUnix: 1, Estimate: 500}, want: 0},
		{name: "a passed instant is due now, not later", route: &pb.Bus_StopEstimate{ArrivalUnix: now.Unix() - 30}, want: 0},
		{name: "a one-second estimate counts", route: &pb.Bus_StopEstimate{Estimate: 1, StopStatus: 1}, want: 1},
		{name: "a zero estimate off normal status has no time", route: &pb.Bus_StopEstimate{StopStatus: 4}, want: -1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := nearbyEtaRemaining(tt.route, now); got != tt.want {
				t.Fatalf("remaining = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestSendNearbyEtaIfChangedIgnoresMapOrder(t *testing.T) {
	src := &nearbyEtaSource{payloads: map[string][]byte{}}
	var groups []*pb.Bus_Ask_StationGroup
	for _, uid := range []string{"A", "B", "C", "D", "E", "F", "G", "H"} {
		src.set(t, "Taipei", uid, &pb.Bus_StationArrival{StationName: uid, Routes: []*pb.Bus_StopEstimate{etaRoute(uid, 60)}})
		groups = append(groups, &pb.Bus_Ask_StationGroup{City: "Taipei", GroupUid: uid})
	}
	var last []byte
	sends := 0
	for range 30 {
		if err := sendNearbyEtaIfChanged(t.Context(), src, groups, &last, func(*pb.Resp_BusStationEtas) error {
			sends++
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	if sends != 1 {
		t.Fatalf("unchanged data was sent %d times, want once", sends)
	}
}
