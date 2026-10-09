package transit

import (
	"context"
	"errors"
	"io"
	"math"
	"sync"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/nearby"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type fakeNearStream struct {
	request  *pb.Ask_Near
	received bool
}

type panicNearbyStore struct{}

func (panicNearbyStore) Find(context.Context, nearby.NearbyMode, nearby.NearbyQuery) ([]nearby.NearbyCandidate, error) {
	panic("nearby store must not be called for an invalid query")
}

func (s *fakeNearStream) Send(*pb.RespNear) error { return nil }
func (s *fakeNearStream) Recv() (*pb.Ask_Near, error) {
	if s.received {
		return nil, io.EOF
	}
	s.received = true
	return s.request, nil
}
func (s *fakeNearStream) SetHeader(metadata.MD) error  { return nil }
func (s *fakeNearStream) SendHeader(metadata.MD) error { return nil }
func (s *fakeNearStream) SetTrailer(metadata.MD)       {}
func (s *fakeNearStream) Context() context.Context     { return context.Background() }
func (s *fakeNearStream) SendMsg(any) error            { return nil }
func (s *fakeNearStream) RecvMsg(any) error            { return nil }

func TestFindNearMapsTotalDiscoveryFailureToUnavailable(t *testing.T) {
	failures := map[nearby.NearbyMode]error{}
	for _, mode := range nearby.AllNearbyModes {
		failures[mode] = errors.New("query failed")
	}
	server := &NearServer{discovery: nearby.NewNearbyDiscovery(
		handlerNearbyStore{rows: map[nearby.NearbyMode][]nearby.NearbyCandidate{}, err: failures},
		handlerWalkingRouter{},
	)}

	err := server.FindNear(&fakeNearStream{request: &pb.Ask_Near{PositionLon: 121.5, PositionLat: 25, Radius: 500}})
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("code = %s, err = %v, want Unavailable", status.Code(err), err)
	}
}

// queuedNearStream feeds requests from a channel and reports EOF once it
// closes, so a test controls exactly when each request reaches the server.
type queuedNearStream struct {
	fakeNearStream
	requests <-chan *pb.Ask_Near
	sent     int
}

func (s *queuedNearStream) Recv() (*pb.Ask_Near, error) {
	in, ok := <-s.requests
	if !ok {
		return nil, io.EOF
	}
	return in, nil
}

func (s *queuedNearStream) Send(*pb.RespNear) error {
	s.sent++
	return nil
}

// blockingNearbyStore records the origin of every query and holds the first one
// open until released, so later requests pile up behind it.
type blockingNearbyStore struct {
	mu      sync.Mutex
	origins []float64
	first   sync.Once
	started chan struct{}
	release chan struct{}
}

func (s *blockingNearbyStore) Find(_ context.Context, mode nearby.NearbyMode, query nearby.NearbyQuery) ([]nearby.NearbyCandidate, error) {
	if mode != nearby.NearbyBus {
		return nil, nil
	}
	s.mu.Lock()
	s.origins = append(s.origins, query.Origin.Lon)
	s.mu.Unlock()
	blocking := false
	s.first.Do(func() { blocking = true })
	if blocking {
		close(s.started)
		<-s.release
	}
	return nil, nil
}

func TestFindNearDropsViewportsSupersededWhileBusy(t *testing.T) {
	requests := make(chan *pb.Ask_Near)
	store := &blockingNearbyStore{started: make(chan struct{}), release: make(chan struct{})}
	stream := &queuedNearStream{requests: requests}
	server := &NearServer{discovery: nearby.NewNearbyDiscovery(store, nil)}

	done := make(chan error, 1)
	go func() { done <- server.FindNear(stream) }()

	ask := func(lon float64) *pb.Ask_Near {
		return &pb.Ask_Near{PositionLon: lon, PositionLat: 25, Radius: 500}
	}
	requests <- ask(121.50)
	<-store.started // the first query is now in flight and blocked
	requests <- ask(121.51)
	requests <- ask(121.52)
	requests <- ask(121.53)
	close(requests)
	close(store.release)

	if err := <-done; err != nil {
		t.Fatalf("FindNear = %v, want nil on client EOF", err)
	}

	store.mu.Lock()
	origins := store.origins
	store.mu.Unlock()
	if len(origins) < 2 || len(origins) > 3 {
		t.Fatalf("served origins = %v, want the first plus at most one more", origins)
	}
	if origins[0] != 121.50 || origins[len(origins)-1] != 121.53 {
		t.Fatalf("served origins = %v, want first 121.50 and last 121.53", origins)
	}
	if stream.sent != len(origins) {
		t.Fatalf("responses = %d, want one per served query (%d)", stream.sent, len(origins))
	}
}

func TestFindNearRejectsInvalidQuery(t *testing.T) {
	server := &NearServer{discovery: nearby.NewNearbyDiscovery(panicNearbyStore{}, nil)}

	err := server.FindNear(&fakeNearStream{request: &pb.Ask_Near{
		PositionLon: math.Inf(1), PositionLat: 25, Radius: 500,
	}})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("code = %s, err = %v, want InvalidArgument", status.Code(err), err)
	}
}

// handlerNearbyStore is the handler-level stand-in for a nearby store. The
// discovery package has its own copy: these tests exercise NearServer, not
// discovery, so the fake stays with the test that drives it.
type handlerNearbyStore struct {
	rows map[nearby.NearbyMode][]nearby.NearbyCandidate
	err  map[nearby.NearbyMode]error
}

func (f handlerNearbyStore) Find(_ context.Context, mode nearby.NearbyMode, _ nearby.NearbyQuery) ([]nearby.NearbyCandidate, error) {
	return f.rows[mode], f.err[mode]
}

// handlerWalkingRouter satisfies the walking seam without doing any routing:
// these tests only reach the handler's failure mapping, never the walk leg.
type handlerWalkingRouter struct{}

func (handlerWalkingRouter) RouteMany(context.Context, nearby.GeoPoint, []nearby.GeoPoint) ([]nearby.WalkingMetric, error) {
	return nil, nil
}
