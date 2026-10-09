package nearby

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"
)

type fakeNearbyStore struct {
	rows map[NearbyMode][]NearbyCandidate
	err  map[NearbyMode]error
}

type failFastNearbyStore struct {
	blockedStarted  chan struct{}
	blockedCanceled chan struct{}
	release         chan struct{}
}

func (f *failFastNearbyStore) Find(ctx context.Context, mode NearbyMode, _ NearbyQuery) ([]NearbyCandidate, error) {
	switch mode {
	case _nearbyBike:
		close(f.blockedStarted)
		select {
		case <-ctx.Done():
			close(f.blockedCanceled)
			return nil, ctx.Err()
		case <-f.release:
			return nil, errors.New("test released blocked query")
		}
	case NearbyBus:
		<-f.blockedStarted
		return nil, errors.New("bus query failed")
	default:
		return nil, nil
	}
}

func (f fakeNearbyStore) Find(_ context.Context, mode NearbyMode, _ NearbyQuery) ([]NearbyCandidate, error) {
	return f.rows[mode], f.err[mode]
}

type fakeWalkingRouter struct {
	metrics []WalkingMetric
	err     error
	calls   int
}

func (f *fakeWalkingRouter) RouteMany(_ context.Context, _ GeoPoint, _ []GeoPoint) ([]WalkingMetric, error) {
	f.calls++
	return f.metrics, f.err
}

func candidate(mode NearbyMode, id, name string, distance float64) NearbyCandidate {
	return NearbyCandidate{
		Mode: mode, ID: id, Name: name, City: "Taipei",
		Point: GeoPoint{Lon: 121.5, Lat: 25}, GeodesicMeters: distance,
	}
}

func TestValidateNearbyQuery(t *testing.T) {
	tests := []struct {
		name       string
		query      NearbyQuery
		wantRadius int
		wantErr    bool
	}{
		{
			name:       "zero radius uses default, snapped",
			query:      NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: 25}},
			wantRadius: 700,
		},
		{
			name:       "minimum positive radius snaps up to one bucket",
			query:      NearbyQuery{Origin: GeoPoint{Lon: -180, Lat: -90}, RadiusMeters: 1},
			wantRadius: _nearbyRadiusBucket,
		},
		{
			name:       "viewport radius snaps up to the next bucket",
			query:      NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: 25}, RadiusMeters: 831},
			wantRadius: 900,
		},
		{
			name:       "already-bucketed radius is unchanged",
			query:      NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: 25}, RadiusMeters: 900},
			wantRadius: 900,
		},
		{
			name:       "maximum radius",
			query:      NearbyQuery{Origin: GeoPoint{Lon: 180, Lat: 90}, RadiusMeters: _maxNearbyRadius},
			wantRadius: _maxNearbyRadius,
		},
		{
			name:    "negative radius",
			query:   NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: 25}, RadiusMeters: -1},
			wantErr: true,
		},
		{
			name:    "radius above maximum",
			query:   NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: 25}, RadiusMeters: 5001},
			wantErr: true,
		},
		{
			name:    "longitude below range",
			query:   NearbyQuery{Origin: GeoPoint{Lon: -180.1, Lat: 25}, RadiusMeters: 500},
			wantErr: true,
		},
		{
			name:    "longitude above range",
			query:   NearbyQuery{Origin: GeoPoint{Lon: 180.1, Lat: 25}, RadiusMeters: 500},
			wantErr: true,
		},
		{
			name:    "latitude below range",
			query:   NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: -90.1}, RadiusMeters: 500},
			wantErr: true,
		},
		{
			name:    "latitude above range",
			query:   NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: 90.1}, RadiusMeters: 500},
			wantErr: true,
		},
		{
			name:    "non-finite longitude",
			query:   NearbyQuery{Origin: GeoPoint{Lon: math.NaN(), Lat: 25}, RadiusMeters: 500},
			wantErr: true,
		},
		{
			name:    "non-finite latitude",
			query:   NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: math.Inf(1)}, RadiusMeters: 500},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := validateNearbyQuery(tt.query)
			if tt.wantErr {
				if !errors.Is(err, ErrInvalidNearbyQuery) {
					t.Fatalf("err = %v, want ErrInvalidNearbyQuery", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.RadiusMeters != tt.wantRadius {
				t.Fatalf("radius = %d, want %d", got.RadiusMeters, tt.wantRadius)
			}
		})
	}
}

func TestNearbyDiscoveryPreservesBusGroupUIDIdentity(t *testing.T) {
	store := fakeNearbyStore{rows: map[NearbyMode][]NearbyCandidate{
		NearbyBus: {
			candidate(NearbyBus, "G-1", "台北車站", 80),
			candidate(NearbyBus, "G-2", "台北車站", 90),
		},
	}, err: map[NearbyMode]error{}}
	router := &fakeWalkingRouter{err: errors.New("osrm unavailable")}

	got, err := NewNearbyDiscovery(store, router).Discover(context.Background(), NearbyQuery{})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.NearBusStations) != 2 {
		t.Fatalf("bus groups = %v, want distinct G-1 and G-2", got.NearBusStations)
	}
	for _, id := range []string{"G-1", "G-2"} {
		group, ok := got.NearBusStations[id]
		if !ok || len(group.NearStations) != 1 || group.NearStations[0].StationID != id {
			t.Fatalf("group %s = %+v, want group_uid as map key and station ID", id, group)
		}
	}
}

func TestNearbyDiscoveryRejectsPartialResponseWhenOneModeFails(t *testing.T) {
	store := fakeNearbyStore{
		rows: map[NearbyMode][]NearbyCandidate{_nearbyBike: {candidate(_nearbyBike, "B-1", "Bike", 160)}},
		err:  map[NearbyMode]error{NearbyBus: errors.New("bus query failed")},
	}

	got, err := NewNearbyDiscovery(store, &fakeWalkingRouter{err: errors.New("osrm unavailable")}).Discover(context.Background(), NearbyQuery{})
	if !errors.Is(err, ErrNearbyUnavailable) {
		t.Fatalf("err = %v, want ErrNearbyUnavailable", err)
	}
	if got != nil {
		t.Fatalf("response = %+v, want nil to prevent partial results", got)
	}
}

func TestNearbyDiscoveryFailsFastAndCancelsSiblingQueries(t *testing.T) {
	store := &failFastNearbyStore{
		blockedStarted:  make(chan struct{}),
		blockedCanceled: make(chan struct{}),
		release:         make(chan struct{}),
	}
	t.Cleanup(func() { close(store.release) })

	result := make(chan error, 1)
	go func() {
		response, err := NewNearbyDiscovery(store, nil).Discover(context.Background(), NearbyQuery{})
		if response != nil {
			result <- errors.New("discovery returned a partial response")
			return
		}
		result <- err
	}()

	select {
	case err := <-result:
		if !errors.Is(err, ErrNearbyUnavailable) {
			t.Fatalf("err = %v, want ErrNearbyUnavailable", err)
		}
	case <-time.After(time.Second):
		t.Fatal("discovery did not fail promptly")
	}

	select {
	case <-store.blockedCanceled:
	case <-time.After(time.Second):
		t.Fatal("blocked sibling query did not observe cancellation")
	}
}

func TestReceiveNearbyModeResultPrefersCallerCancellationOverReadyDatabaseError(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	results := make(chan nearbyModeResult, 1)
	ready := make(chan struct{})
	go func() {
		results <- nearbyModeResult{mode: NearbyBus, queryError: errors.New("bus query failed")}
		cancel()
		close(ready)
	}()
	<-ready

	result, err := receiveNearbyModeResult(ctx, results)
	if err != context.Canceled {
		t.Fatalf("err = %v, want exact context.Canceled", err)
	}
	if result.mode != 0 || result.candidates != nil || result.queryError != nil {
		t.Fatalf("result = %+v, want zero value when caller context is canceled", result)
	}
}

func TestNearbyDiscoveryReturnsUnavailableWhenEveryModeFails(t *testing.T) {
	failures := map[NearbyMode]error{}
	for _, mode := range AllNearbyModes {
		failures[mode] = errors.New("query failed")
	}

	_, err := NewNearbyDiscovery(fakeNearbyStore{rows: map[NearbyMode][]NearbyCandidate{}, err: failures}, &fakeWalkingRouter{}).
		Discover(context.Background(), NearbyQuery{})
	if !errors.Is(err, ErrNearbyUnavailable) {
		t.Fatalf("err = %v, want ErrNearbyUnavailable", err)
	}
}

func TestNearbyDiscoveryFallsBackWhenRoutingFails(t *testing.T) {
	store := fakeNearbyStore{rows: map[NearbyMode][]NearbyCandidate{
		_nearbyTRA: {candidate(_nearbyTRA, "T-1", "TRA", 800)},
	}, err: map[NearbyMode]error{}}

	got, err := NewNearbyDiscovery(store, &fakeWalkingRouter{err: errors.New("osrm unavailable")}).Discover(context.Background(), NearbyQuery{})
	if err != nil {
		t.Fatal(err)
	}
	station := got.NearTraStations[0]
	if station.Walk != 10 || station.Distance != 800 || station.Routed {
		t.Fatalf("station = %+v, want geodesic fallback", station)
	}
}

func TestNearbyDiscoverySkipsRoutingForEmptyCandidates(t *testing.T) {
	router := &fakeWalkingRouter{}
	_, err := NewNearbyDiscovery(fakeNearbyStore{rows: map[NearbyMode][]NearbyCandidate{}, err: map[NearbyMode]error{}}, router).
		Discover(context.Background(), NearbyQuery{})
	if err != nil {
		t.Fatal(err)
	}
	if router.calls != 0 {
		t.Fatalf("routing calls = %d, want 0", router.calls)
	}
}

// indexWalkingRouter answers with one metric per requested point, minute i for
// point i, so a mis-sliced metric window shows up as a wrong Walk value.
type indexWalkingRouter struct {
	calls  int
	points int
}

func (r *indexWalkingRouter) RouteMany(_ context.Context, _ GeoPoint, points []GeoPoint) ([]WalkingMetric, error) {
	r.calls++
	r.points = len(points)
	metrics := make([]WalkingMetric, len(points))
	for i := range points {
		seconds := float64(i * 60)
		metrics[i] = WalkingMetric{DurationSeconds: &seconds}
	}
	return metrics, nil
}

func TestNearbyDiscoveryRoutesEveryModeInOneTableRequest(t *testing.T) {
	store := fakeNearbyStore{rows: map[NearbyMode][]NearbyCandidate{
		NearbyBus:  {candidate(NearbyBus, "G-1", "Bus", 80), candidate(NearbyBus, "G-2", "Bus", 90)},
		_nearbyMRT: {candidate(_nearbyMRT, "M-1", "MRT", 300)},
	}, err: map[NearbyMode]error{}}
	router := &indexWalkingRouter{}

	got, err := NewNearbyDiscovery(store, router).Discover(context.Background(), NearbyQuery{})
	if err != nil {
		t.Fatal(err)
	}
	if router.calls != 1 || router.points != 3 {
		t.Fatalf("routing calls = %d over %d points, want 1 call over 3", router.calls, router.points)
	}
	for id, wantWalk := range map[string]int32{"G-1": 0, "G-2": 1} {
		if station := got.NearBusStations[id].NearStations[0]; station.Walk != wantWalk || !station.Routed {
			t.Fatalf("bus %s = %+v, want walk %d routed", id, station, wantWalk)
		}
	}
	// The MRT candidate sits at flat index 2, after both bus groups.
	if station := got.NearMrtStations[0]; station.Walk != 2 || !station.Routed {
		t.Fatalf("mrt station = %+v, want walk 2 routed", station)
	}
}

func TestNearbyDiscoveryServesRepeatQueryFromCache(t *testing.T) {
	store := fakeNearbyStore{rows: map[NearbyMode][]NearbyCandidate{
		_nearbyTRA: {candidate(_nearbyTRA, "T-1", "TRA", 800)},
	}, err: map[NearbyMode]error{}}
	router := &indexWalkingRouter{}
	discovery := NewNearbyDiscovery(store, router)
	query := NearbyQuery{Origin: GeoPoint{Lon: 121.5, Lat: 25}, RadiusMeters: 670}

	first, err := discovery.Discover(context.Background(), query)
	if err != nil {
		t.Fatal(err)
	}
	second, err := discovery.Discover(context.Background(), query)
	if err != nil {
		t.Fatal(err)
	}
	if router.calls != 1 {
		t.Fatalf("routing calls = %d, want 1 (second query cached)", router.calls)
	}
	if second.NearTraStations[0].StationID != first.NearTraStations[0].StationID {
		t.Fatalf("cached response = %+v, want the same station as %+v", second, first)
	}
}

func TestNearbyDiscoveryPropagatesContextCancellation(t *testing.T) {
	store := fakeNearbyStore{rows: map[NearbyMode][]NearbyCandidate{
		_nearbyMRT: {candidate(_nearbyMRT, "M-1", "MRT", 80)},
	}, err: map[NearbyMode]error{}}

	_, err := NewNearbyDiscovery(store, &fakeWalkingRouter{err: context.Canceled}).Discover(context.Background(), NearbyQuery{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
}
