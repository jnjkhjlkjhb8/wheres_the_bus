package nearby

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-resty/resty/v2"
)

func TestMotisWalkingRouterPreservesOrderAndNullableCells(t *testing.T) {
	var body motisOneToManyRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method = %q, want POST", r.Method)
		}
		if r.URL.Path != _motisOneToManyPath {
			t.Errorf("path = %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode body: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{"duration":300,"distance":450},{}]`))
	}))
	defer server.Close()

	router := NewMotisWalkingRouter(resty.New(), server.URL)
	got, err := router.RouteMany(context.Background(), GeoPoint{Lon: 121.5, Lat: 25}, []GeoPoint{
		{Lon: 121.51, Lat: 25.01},
		{Lon: 121.52, Lat: 25.02},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 ||
		got[0].DurationSeconds == nil || *got[0].DurationSeconds != 300 ||
		got[1].DurationSeconds != nil {
		t.Fatalf("metrics = %+v, want ordered duration then null", got)
	}
	if got[0].DistanceMeters == nil || *got[0].DistanceMeters != 450 {
		t.Fatalf("distance = %+v, want 450", got[0].DistanceMeters)
	}
	// latitude;longitude, because the comma separates locations from each other.
	if body.One != "25.000000;121.500000" {
		t.Errorf("one = %q", body.One)
	}
	if len(body.Many) != 2 || body.Many[0] != "25.010000;121.510000" {
		t.Errorf("many = %q", body.Many)
	}
	if body.Mode != "WALK" ||
		body.Max != _motisWalkMaxSeconds ||
		body.MaxMatchingDistance != _motisWalkMatchingMeters {
		t.Errorf("profile = %q max = %v matching = %v", body.Mode, body.Max, body.MaxMatchingDistance)
	}
	// nearby.go puts the distance on screen, so a duration-only query would be
	// a silent regression rather than an optimisation.
	if !body.WithDistance {
		t.Error("withDistance = false, want true")
	}
}

// A response that does not line up with the request is refused rather than
// zipped: pairing stop i with entry i is the only thing that ties the two lists
// together, and a short array would quote one stop's walk for another's.
func TestMotisWalkingRouterRejectsLengthMismatch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{"duration":300}]`))
	}))
	defer server.Close()

	_, err := NewMotisWalkingRouter(resty.New(), server.URL).RouteMany(
		context.Background(),
		GeoPoint{Lon: 121.5, Lat: 25},
		[]GeoPoint{{Lon: 121.51, Lat: 25.01}, {Lon: 121.52, Lat: 25.02}},
	)
	if err == nil {
		t.Fatal("err = nil, want a length mismatch error")
	}
}

func TestMotisWalkingRouterPropagatesContextCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := NewMotisWalkingRouter(resty.New(), server.URL).
		RouteMany(ctx, GeoPoint{}, []GeoPoint{{Lon: 1, Lat: 1}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
}
