package nearby

import (
	"context"
	"errors"
	"testing"
)

func TestMotisWalkingRouterHandlesEmptyAndUnavailableClients(t *testing.T) {
	for _, router := range []*motisWalkingRouter{nil, {}} {
		if got, err := router.RouteMany(t.Context(), GeoPoint{}, nil); got != nil || err != nil {
			t.Fatalf("empty destinations = %v, error %v", got, err)
		}
		if got, err := router.RouteMany(t.Context(), GeoPoint{}, []GeoPoint{{Lat: 1}}); got != nil || err == nil {
			t.Fatalf("unavailable client = %v, error %v", got, err)
		}
	}
}

func TestNearbyRoutedDistanceOverridesGeodesicEstimate(t *testing.T) {
	duration, distance := 180.0, 245.0
	item := candidate(_nearbyBike, "bike", "Bike", 800)
	got := nearbyStations([]NearbyCandidate{item}, []WalkingMetric{{DurationSeconds: &duration, DistanceMeters: &distance}})
	if len(got) != 1 || got[0].Walk != 3 || got[0].Distance != 245 || !got[0].Routed {
		t.Fatalf("routed station = %v", got)
	}
}

func TestNearbyCollectionReturnsCancellationWithoutWaitingForModes(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	got, err := collectNearbyModes(ctx, make(chan nearbyModeResult))
	if got != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled collection = %v, error %v", got, err)
	}
}

func TestNearbyBudgetDoesNotRetainCancelledWaiter(t *testing.T) {
	for range cap(nearbyBudget) {
		nearbyBudget <- struct{}{}
	}
	t.Cleanup(func() {
		for range cap(nearbyBudget) {
			<-nearbyBudget
		}
	})
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	discovery := NewNearbyDiscovery(fakeNearbyStore{}, nil)
	got, err := discovery.discoverFresh(ctx, NearbyQuery{}, "cancelled")
	if got != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled budget waiter = %v, error %v", got, err)
	}
	if len(nearbyBudget) != cap(nearbyBudget) {
		t.Fatal("cancelled waiter released another request's budget slot")
	}
}
