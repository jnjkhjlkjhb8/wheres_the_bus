package maas

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

// A single failed check must not flip the reported health. Flipping is the
// visible action; observing is cheap. One dropped packet or one
// restart mid-deploy is not evidence.
func TestPlannerHealthRequiresConsecutiveChecksBeforeSwitching(t *testing.T) {
	var healthy atomic.Bool
	healthy.Store(true)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if !healthy.Load() {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"rt":false,"gbfs":true}`))
			return
		}
		_, _ = w.Write([]byte(`{"rt":true,"gbfs":true}`))
	}))
	defer server.Close()

	monitor := NewPlannerHealthMonitor(NewMotisHealthClient(server.URL))
	ctx := t.Context()

	monitor.check(ctx)
	if !monitor.Status().Healthy {
		t.Fatal("a healthy MOTIS was reported unhealthy")
	}

	healthy.Store(false)
	monitor.check(ctx)
	if !monitor.Status().Healthy {
		t.Fatal("one failed check flipped health; the threshold is 2")
	}
	monitor.check(ctx)
	if monitor.Status().Healthy {
		t.Fatal("two consecutive failed checks did not flip health")
	}

	// And back: a recovery needs the same evidence a failure did.
	healthy.Store(true)
	monitor.check(ctx)
	if monitor.Status().Healthy {
		t.Fatal("one successful check flipped back; the threshold is 2")
	}
	monitor.check(ctx)
	if !monitor.Status().Healthy {
		t.Fatal("two consecutive successful checks did not restore MOTIS")
	}
}

func TestPlannerHealthResetsTheStreakOnDisagreement(t *testing.T) {
	var fail atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if fail.Load() {
			w.WriteHeader(http.StatusBadRequest)
		}
		_, _ = w.Write([]byte(`{"rt":true,"gbfs":true}`))
	}))
	defer server.Close()

	monitor := NewPlannerHealthMonitor(NewMotisHealthClient(server.URL))
	ctx := t.Context()
	for _, shouldFail := range []bool{true, false, true, false, true} {
		fail.Store(shouldFail)
		monitor.check(ctx)
	}
	if !monitor.Status().Healthy {
		t.Fatal("alternating failures flipped health; the streak must reset")
	}
}

// An unreachable MOTIS is the same verdict as a 400: neither can answer with
// current data.
func TestPlannerHealthTreatsUnreachableAsUnhealthy(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	serverURL := server.URL
	server.Close()

	monitor := NewPlannerHealthMonitor(NewMotisHealthClient(serverURL))
	monitor.check(t.Context())
	monitor.check(t.Context())
	if monitor.Status().Healthy {
		t.Fatal("an unreachable MOTIS is still reported healthy")
	}
	if status := monitor.Status(); status.Backend != "motis" {
		t.Errorf("backend = %q, want motis", status.Backend)
	}
}

// The app reads the capability list to decide which options to offer. It stays
// the full MOTIS set even when MOTIS reports stale feeds: plans still go there.
func TestPlannerStatusAlwaysAdvertisesTheFullCapabilitySet(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"rt":false,"gbfs":false}`))
	}))
	defer server.Close()
	monitor := NewPlannerHealthMonitor(NewMotisHealthClient(server.URL))
	monitor.check(t.Context())
	monitor.check(t.Context())

	engine := gin.New()
	RegisterPlannerStatusRoutes(engine, monitor, func(c *gin.Context) { c.Next() })
	recorder := httptest.NewRecorder()
	engine.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, PlannerStatusPath, nil))
	var body plannerStatusBody
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Healthy || body.Backend != "motis" {
		t.Fatalf("status = %+v, want unhealthy motis", body.PlannerStatus)
	}
	if got := body.Capabilities; len(got) != len(plannerCapabilities()) || got[0] != _capTransitModes {
		t.Fatalf("capabilities = %v", got)
	}
}

// The degraded reason has to name which half is stale, or an operator reading
// /api/planner learns only that something is wrong.
func TestPlannerHealthReasonNamesTheStaleFeed(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"rt":false,"gbfs":true}`))
	}))
	defer server.Close()

	monitor := NewPlannerHealthMonitor(NewMotisHealthClient(server.URL))
	ctx := t.Context()
	monitor.check(ctx)
	monitor.check(ctx)

	status := monitor.Status()
	if status.Realtime || !status.Bikeshare {
		t.Errorf("feeds = rt:%v gbfs:%v, want rt stale only", status.Realtime, status.Bikeshare)
	}
	if want := "realtime stale"; !strings.Contains(status.Reason, want) {
		t.Errorf("reason = %q, want it to mention %q", status.Reason, want)
	}
	if status.ChangedAt == "" {
		t.Error("a backend change must record when it happened")
	}
	if _, err := time.Parse(time.RFC3339, status.CheckedAt); err != nil {
		t.Errorf("checkedAt = %q: %v", status.CheckedAt, err)
	}
}
