package maas

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestMotisLabelsPreserveDisplayPriorityAndPlaceKind(t *testing.T) {
	for _, tc := range []struct {
		leg  motisLeg
		want string
	}{
		{motisLeg{DisplayName: "display", RouteShortName: "short", RouteLongName: "long"}, "display"},
		{motisLeg{RouteShortName: "short", RouteLongName: "long"}, "short"},
		{motisLeg{RouteLongName: "long"}, "long"},
		{motisLeg{}, ""},
	} {
		if got := motisRouteName(tc.leg); got != tc.want {
			t.Fatalf("route name = %q, want %q", got, tc.want)
		}
	}
	for mode, want := range map[string]string{"BUS": "transit", "SUBWAY": "transit", "WALK": "pedestrian", "unknown": "pedestrian"} {
		if got := motisSectionType(mode); got != want {
			t.Fatalf("section type for %q = %q, want %q", mode, got, want)
		}
	}
	if got := motisPlaceType(motisPlace{StopID: "stop"}); got != "station" {
		t.Fatalf("stop kind = %q", got)
	}
	if got := motisPlaceType(motisPlace{}); got != "place" {
		t.Fatalf("coordinate kind = %q", got)
	}
}

func TestMotisRequestKeepsClockAndMileTimeUnits(t *testing.T) {
	now := time.Date(2026, 10, 10, 8, 0, 0, 0, time.Local)
	for _, clock := range []string{"12:34", "12:34:00"} {
		query := motisPlanQuery(&pb.MaasPlanRequest{Date: "2026-10-10", Time: clock, FirstMileTime: 7, LastMileTime: 13}, now)
		want := time.Date(2026, 10, 10, 12, 34, 0, 0, time.Local).Format(time.RFC3339)
		if query.Get("time") != want || query.Get("maxPreTransitTime") != "420" || query.Get("maxPostTransitTime") != "780" {
			t.Fatalf("request time and mile limits = %v", query)
		}
		if query.Has("transitModes") {
			t.Fatal("unspecified modes sent an empty transit filter")
		}
	}
}

func TestRouteRankingNormalizesAxesAndPreservesEqualCostOrder(t *testing.T) {
	if got := normaliseRouteAxis(15, 10, 30); got != 0.25 {
		t.Fatalf("normalized axis = %v, want .25", got)
	}
	first, second := &pb.Route{TravelTime: 600, TotalFare: 20}, &pb.Route{TravelTime: 600, TotalFare: 20}
	response := &pb.MaasPlanResponse{Routes: []*pb.Route{first, second}}
	rankMotisRoutes(response, 0.5, 2)
	if !reflect.DeepEqual(response.Routes, []*pb.Route{first, second}) || response.Routes[0] != first {
		t.Fatal("equal-cost routes lost their upstream order")
	}
}

func TestPlannerClientsRetainConfiguredTimeoutsAndRetryWait(t *testing.T) {
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	server := NewMaasServerWithCache(newControlledMaasCache(), nil, tdx, maasSharedWorkConfig{})
	defer server.Close()
	if server.maasClient.RetryWaitTime != 500*time.Millisecond || server.maasClient.RetryCount != 3 || server.osrmClient.GetClient().Timeout != 5*time.Second || server.workTimeout != 20*time.Second {
		t.Fatalf("client retries = %d at %v, walking timeout %v, work timeout %v", server.maasClient.RetryCount, server.maasClient.RetryWaitTime, server.osrmClient.GetClient().Timeout, server.workTimeout)
	}
}

func TestPlannerGetReturnsUpstreamCancellation(t *testing.T) {
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	server := NewMaasServerWithCache(newControlledMaasCache(), nil, tdx, DefaultMaasSharedWorkConfig)
	defer server.Close()
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	got, err := server.get(ctx, &pb.MaasPlanRequest{})
	if got != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled plan = %v, error %v", got, err)
	}
}

func TestTransitShapeAcceptsCoordinatesOnEitherAxis(t *testing.T) {
	for _, point := range []transitStopPoint{{lat: 25}, {lng: 121}} {
		db, err := pgxmock.NewPool()
		if err != nil {
			t.Fatal(err)
		}
		db.ExpectQuery("WITH candidates").WithArgs("metro", point.lng, point.lat, 121.0, 25.0, _railShapeSnapMeters, _railShapeSimplifyTolerance).WillReturnError(errors.New("no shape"))
		if got, ok := clipRailShape(t.Context(), db, "metro", point, transitStopPoint{25, 121}); got != nil || ok {
			t.Fatalf("unavailable clip = %v, success %v", got, ok)
		}
		if err := db.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
		db.Close()
	}
}

func TestTransitEnrichmentBuildsOrderedShapeAndHonorsGuards(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	source := tdxSection{Transport: tdxTransport{Mode: "METRO"}}
	source.Departure.Place.Location = tdxLocation{Lat: 25, Lng: 121}
	source.Arrival.Place.Location = tdxLocation{Lat: 26, Lng: 122}
	target := &pb.Section{}
	ref := maasSectionRef{source: source, target: target}
	db.ExpectQuery("WITH candidates").WithArgs("metro", 121.0, 25.0, 122.0, 26.0, _railShapeSnapMeters, _railShapeSimplifyTolerance).WillReturnRows(pgxmock.NewRows([]string{"wkt"}).AddRow("LINESTRING(121 25,121.5 25.5,122 26)")).RowsWillBeClosed()
	enrichTransitPaths(t.Context(), db, []maasSectionRef{ref})
	want := []*pb.Location{{Lat: 25, Lng: 121}, {Lat: 25.5, Lng: 121.5}, {Lat: 26, Lng: 122}}
	if !reflect.DeepEqual(target.TransitPath, want) {
		t.Fatalf("transit path = %v, want %v", target.TransitPath, want)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := enrichTransitPath(ctx, db, "metro", ref); !errors.Is(err, context.Canceled) || !reflect.DeepEqual(target.TransitPath, want) {
		t.Fatalf("cancelled enrichment error = %v, path %v", err, target.TransitPath)
	}
	enrichTransitPaths(t.Context(), nil, []maasSectionRef{ref})
	ref.source.Transport.Mode = "BUS"
	enrichTransitPaths(t.Context(), db, []maasSectionRef{ref})
	if !reflect.DeepEqual(target.TransitPath, want) {
		t.Fatal("unavailable or inapplicable enrichment overwrote existing shape")
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
