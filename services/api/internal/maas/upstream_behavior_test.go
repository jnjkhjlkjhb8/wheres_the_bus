package maas

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestMotisPlanPreservesCursorsAndClassifiesNoRoute(t *testing.T) {
	for _, tc := range []struct {
		name             string
		status           int
		body             string
		noRoute, success bool
	}{
		{"success", 200, `{"itineraries":[{"duration":90,"legs":[]}],"previousPageCursor":"before","nextPageCursor":"after"}`, false, true},
		{"empty", 200, `{"itineraries":[]}`, true, false},
		{"not found", 404, `{"error":"no route"}`, true, false},
		{"failure", 503, `{"error":"unavailable"}`, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != _motisPlanPath {
					t.Errorf("path = %q", r.URL.Path)
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer upstream.Close()
			got, err := NewMotisClient(upstream.URL).Plan(t.Context(), &pb.MaasPlanRequest{Date: "2026-10-10", Time: "12:00"})
			if tc.success {
				if err != nil || got == nil || got.previous != "before" || got.next != "after" || len(got.api.Data.Routes) != 1 {
					t.Fatalf("plan = %+v, error %v", got, err)
				}
			} else if err == nil || got != nil || errors.Is(err, errMaasNoRoute) != tc.noRoute {
				t.Fatalf("failed plan = %+v, error %v", got, err)
			}
		})
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if got, err := NewMotisClient("http://127.0.0.1:1").Plan(ctx, &pb.MaasPlanRequest{}); got != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled plan = %+v, error %v", got, err)
	}
}

func TestWalkInstructionsShareDirectionVocabulary(t *testing.T) {
	for _, tc := range []struct{ direction, street, want string }{
		{"DEPART", "道路", "沿道路出發"}, {"DEPART", "", "開始步行"}, {"ARRIVE", "ignored", "抵達目的地"},
		{"LEFT", "道路", "左轉進入道路"}, {"CONTINUE_LEFT", "", "左轉"}, {"RIGHT", "", "右轉"}, {"CONTINUE_RIGHT", "", "右轉"},
		{"HARD_LEFT", "", "向左急轉"}, {"HARD_RIGHT", "", "向右急轉"}, {"SLIGHTLY_LEFT", "", "稍向左"}, {"SLIGHTLY_RIGHT", "", "稍向右"},
		{"UTURN_LEFT", "", "迴轉"}, {"UTURN_RIGHT", "", "迴轉"}, {"CONTINUE", "道路", "沿道路直走"}, {"unknown", "", "繼續直走"},
	} {
		got := motisStepInstruction(motisStep{RelativeDirection: strings.ToLower(tc.direction), StreetName: tc.street})
		if got != tc.want {
			t.Errorf("instruction %s/%s = %q, want %q", tc.direction, tc.street, got, tc.want)
		}
	}
	geometry := motisLegGeometry(motisLeg{Mode: "WALK", Steps: []motisStep{{RelativeDirection: "LEFT", StreetName: "道路", Distance: 12, Polyline: motisPolyline{Points: "_p~iF~ps|U", Precision: 5}}}})
	if geometry == nil || len(geometry.steps) != 1 || geometry.steps[0].Location == nil || geometry.steps[0].Location.Lat != 38.5 || geometry.steps[0].DistanceMeters != 12 {
		t.Fatalf("walk geometry = %+v", geometry)
	}
}

func TestRailShapeClippingRequiresCompleteDecodableGeometry(t *testing.T) {
	for _, tc := range []struct {
		name, wkt string
		scanErr   bool
		want      bool
	}{
		{"line", "LINESTRING(121 25,122 26)", false, true},
		{"point", "POINT(121 25)", false, false},
		{"single coordinate", "LINESTRING(121 25)", false, false},
		{"invalid latitude", "LINESTRING(121 bad,122 26)", false, false},
		{"invalid longitude", "LINESTRING(bad 25,122 26)", false, false},
		{"short coordinate", "LINESTRING(121,122 26)", false, false},
		{"scan failure", "", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			rows := pgxmock.NewRows([]string{"wkt"})
			if tc.scanErr {
				rows.AddRow(errors.New("scan failure"))
			} else {
				rows.AddRow(tc.wkt)
			}
			db.ExpectQuery("WITH candidates").WithArgs("metro", 121.0, 25.0, 122.0, 26.0, _railShapeSnapMeters, _railShapeSimplifyTolerance).WillReturnRows(rows).RowsWillBeClosed()
			got, ok := clipRailShape(t.Context(), db, "metro", transitStopPoint{25, 121}, transitStopPoint{26, 122})
			if ok != tc.want || tc.want && (len(got) != 2 || got[0].Lng != 121 || got[1].Lat != 26) {
				t.Fatalf("clipped shape = %v, success %v", got, ok)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPlannerHealthStartPollsUntilCancelled(t *testing.T) {
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"rt":true,"gbfs":true}`))
	}))
	defer upstream.Close()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	monitor := NewPlannerHealthMonitor(NewMotisHealthClient(upstream.URL))
	monitor.interval = time.Millisecond
	monitor.Start(ctx)
	if calls.Load() != 1 || monitor.Status().CheckedAt == "" {
		t.Fatal("initial health check did not complete before Start returned")
	}
	deadline := time.Now().Add(time.Second)
	for calls.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	cancel()
	if calls.Load() < 2 {
		t.Fatal("periodic health check did not run")
	}
	for _, tc := range []struct {
		body motisHealthResponse
		want string
	}{
		{motisHealthResponse{}, " (realtime and bikeshare both stale)"},
		{motisHealthResponse{GBFS: true}, " (realtime stale)"},
		{motisHealthResponse{RT: true}, " (bikeshare stale)"},
		{motisHealthResponse{RT: true, GBFS: true}, ""},
	} {
		if got := describeFeeds(tc.body); got != tc.want {
			t.Errorf("feed description = %q, want %q", got, tc.want)
		}
	}
}
