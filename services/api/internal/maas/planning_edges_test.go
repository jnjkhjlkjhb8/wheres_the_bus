package maas

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/pashagolub/pgxmock/v4"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestPlanFailureRetainsContextAndKnownStatus(t *testing.T) {
	for _, tc := range []struct {
		err  error
		code codes.Code
	}{
		{context.Canceled, codes.Canceled}, {context.DeadlineExceeded, codes.DeadlineExceeded},
		{status.Error(codes.ResourceExhausted, "limit"), codes.ResourceExhausted},
		{errors.New("unavailable"), codes.Unavailable}, {errMaasNoRoute, codes.NotFound},
	} {
		if got := status.Code(maasPlanError(tc.err)); got != tc.code {
			t.Errorf("error %v maps to %v, want %v", tc.err, got, tc.code)
		}
	}
}

func TestCancelledPlanDoesNotReachUpstreamAfterCacheMiss(t *testing.T) {
	server := NewMaasServerWithCache(newControlledMaasCache(), nil, DefaultMaasSharedWorkConfig)
	defer server.Close()
	req := &pb.MaasPlanRequest{}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	stream := &recordingPlanStream{ctx: ctx}
	if err := server.streamPlan(ctx, req, stream); status.Code(err) != codes.Canceled || len(stream.updates) != 0 {
		t.Fatalf("cancelled stream error=%v, updates=%v", err, stream.updates)
	}
	server.lifecycleCancel()
	if response, err := server.runSharedPlan("key", req); response != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled shared plan=%v, error=%v", response, err)
	}
	if len(server.workSlots) != 0 {
		t.Fatal("cancelled work retained a permit")
	}
}

func TestMaasCacheWriteFailureDoesNotDiscardCompletedStream(t *testing.T) {
	cache := newControlledMaasCache()
	cache.setBlock = make(chan struct{})
	server := &MaasServer{cache: cache}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	server.cachePlan(ctx, "cancelled", &pb.MaasPlanResponse{})
	if cache.setCalls.Load() != 1 {
		t.Fatal("cache write was not attempted")
	}
}

func TestMaasEnrichmentAppliesMotisWalkGeometry(t *testing.T) {
	server := &MaasServer{}
	section := &pb.Section{}
	geometry := &motisWalkGeometry{path: []*pb.Location{{Lat: 25, Lng: 121}}}
	server.enrich(t.Context(), []maasSectionRef{{target: section}}, []*motisWalkGeometry{geometry})
	if len(section.WalkPath) != 1 || section.WalkPath[0].Lat != 25 {
		t.Fatal("MOTIS walk geometry was not applied")
	}
	server.enrich(t.Context(), nil, []*motisWalkGeometry{geometry})
}

func TestRailShapeQueryFailureAndMissingRowAreRecoverable(t *testing.T) {
	for _, kind := range []string{"query", "empty"} {
		t.Run(kind, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			expected := db.ExpectQuery("WITH candidates").WithArgs("metro", 121.0, 25.0, 122.0, 26.0, _railShapeSnapMeters, _railShapeSimplifyTolerance)
			if kind == "query" {
				expected.WillReturnError(errors.New("unavailable"))
			} else {
				expected.WillReturnRows(pgxmock.NewRows([]string{"wkt"})).RowsWillBeClosed()
			}
			if points, ok := clipRailShape(t.Context(), db, "metro", transitStopPoint{25, 121}, transitStopPoint{26, 122}); ok || points != nil {
				t.Fatalf("failed query returned %v/%v", points, ok)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestMotisModesDeduplicateAndRejectIncompletePolyline(t *testing.T) {
	modes := motisTransitModes([]int32{5, 5, 6, 999})
	if strings.Join(modes, ",") != "BUS,COACH,SUBWAY" {
		t.Fatalf("deduplicated modes=%v", modes)
	}
	if got := decodeMotisPolyline(motisPolyline{Points: strings.Repeat("~", 14), Precision: 5}); len(got) != 0 {
		t.Fatalf("overflow polyline=%v", got)
	}
	for _, response := range []*pb.MaasPlanResponse{nil, {}, {Routes: []*pb.Route{{TotalFare: 20}}}} {
		rankMotisRoutes(response, 1, 5)
	}
}

func TestMotisBaseURLFromEnv(t *testing.T) {
	t.Setenv(_motisBaseURLEnv, "")
	if got := MotisBaseURLFromEnv(); got != _motisDefaultBaseURL {
		t.Fatalf("default URL=%s", got)
	}
	t.Setenv(_motisBaseURLEnv, " http://localhost:8080/// ")
	if got := MotisBaseURLFromEnv(); got != "http://localhost:8080" {
		t.Fatalf("trimmed URL=%s", got)
	}
}

type failingMaasCache struct{ *controlledMaasCache }

func (c failingMaasCache) Set(context.Context, string, []byte, time.Duration) error {
	c.setCalls.Add(1)
	return errors.New("cache unavailable")
}

func TestCompletedPlanCacheFailureIsBestEffort(t *testing.T) {
	cache := failingMaasCache{newControlledMaasCache()}
	server := &MaasServer{cache: cache}
	response := &pb.MaasPlanResponse{NextPageCursor: "next"}
	server.cachePlan(t.Context(), "stream", response)
	got, err := server.persistSharedPlan(t.Context(), "shared", response)
	if err != nil || got != response || cache.setCalls.Load() != 2 {
		t.Fatalf("completed response=%v, error=%v, writes=%d", got, err, cache.setCalls.Load())
	}
}

func TestSharedPlanCacheHitSkipsUpstreamAndStreamQuotaIsBounded(t *testing.T) {
	cache := newControlledMaasCache()
	response := &pb.MaasPlanResponse{NextPageCursor: "cached"}
	encoded, err := proto.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	cache.data["hit"] = encoded
	server := NewMaasServerWithCache(cache, nil, maasSharedWorkConfig{MaxConcurrent: 1})
	defer server.Close()
	got, err := server.runSharedPlan("hit", &pb.MaasPlanRequest{})
	if err != nil || !proto.Equal(got, response) || cache.setCalls.Load() != 0 {
		t.Fatalf("cache hit=%v, error=%v", got, err)
	}
	release, err := server.acquireWorkSlot()
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	stream := &recordingPlanStream{ctx: t.Context()}
	if err := server.PlanStream(&pb.MaasPlanRequest{}, stream); status.Code(err) != codes.ResourceExhausted || len(stream.updates) != 0 {
		t.Fatalf("quota stream error=%v, updates=%v", err, stream.updates)
	}
}

func TestMotisEmptyAndTruncatedWalkGeometryIsNotPublished(t *testing.T) {
	if geometry := motisLegGeometry(motisLeg{Mode: "WALK"}); geometry != nil {
		t.Fatalf("empty geometry=%v", geometry)
	}
	if got := decodeMotisPolyline(motisPolyline{Points: "~", Precision: 5}); len(got) != 0 {
		t.Fatalf("truncated geometry=%v", got)
	}
}

func TestMotisPlanNotFoundAndFailureClassification(t *testing.T) {
	for _, tc := range []struct {
		name    string
		status  int
		noRoute bool
	}{{"not found", http.StatusNotFound, true}, {"server error", http.StatusInternalServerError, false}} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(tc.status) }))
			defer upstream.Close()
			server := newMotisTestServer(newControlledMaasCache(), DefaultMaasSharedWorkConfig, upstream.URL)
			defer server.Close()
			got, err := server.get(t.Context(), &pb.MaasPlanRequest{})
			if got != nil || err == nil || errors.Is(err, errMaasNoRoute) != tc.noRoute {
				t.Fatalf("response=%v, error=%v", got, err)
			}
		})
	}
	server := newMotisTestServer(newControlledMaasCache(), DefaultMaasSharedWorkConfig, "http://127.0.0.1:1")
	defer server.Close()
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if got, err := server.get(ctx, &pb.MaasPlanRequest{}); got != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("transport failure response=%v, error=%v", got, err)
	}
}

func TestOversizedTransitModesAreRejectedBeforeAnyWork(t *testing.T) {
	cache := newControlledMaasCache()
	server := NewMaasServerWithCache(cache, nil, DefaultMaasSharedWorkConfig)
	defer server.Close()
	req := &pb.MaasPlanRequest{TransitModes: make([]int32, maxTransitModes+1)}
	if _, err := server.Plan(t.Context(), req); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("plan error = %v, want InvalidArgument", err)
	}
	stream := &recordingPlanStream{ctx: t.Context()}
	if err := server.PlanStream(req, stream); status.Code(err) != codes.InvalidArgument || len(stream.updates) != 0 {
		t.Fatalf("stream error = %v, updates = %v", err, stream.updates)
	}
	if err := checkTransitModes(&pb.MaasPlanRequest{TransitModes: make([]int32, maxTransitModes)}); err != nil {
		t.Fatalf("modes at cap rejected: %v", err)
	}
	if got := motisTransitModes([]int32{5, 5, 6, 99}); strings.Join(got, ",") != "BUS,COACH,SUBWAY" {
		t.Fatalf("modes = %v", got)
	}
}
