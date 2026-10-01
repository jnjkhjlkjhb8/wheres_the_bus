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

// A single failed check must not move riders onto TDX. Switching backend is the
// visible, expensive action; observing is cheap. One dropped packet or one
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
	if !monitor.UseMotis() {
		t.Fatal("a healthy MOTIS was not used")
	}

	healthy.Store(false)
	monitor.check(ctx)
	if !monitor.UseMotis() {
		t.Fatal("one failed check switched the backend; the threshold is 2")
	}
	monitor.check(ctx)
	if monitor.UseMotis() {
		t.Fatal("two consecutive failed checks did not switch the backend")
	}

	// And back: a recovery needs the same evidence a failure did.
	healthy.Store(true)
	monitor.check(ctx)
	if monitor.UseMotis() {
		t.Fatal("one successful check switched back; the threshold is 2")
	}
	monitor.check(ctx)
	if !monitor.UseMotis() {
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
	if !monitor.UseMotis() {
		t.Fatal("alternating failures tripped the switch; the streak must reset")
	}
}

// An unreachable MOTIS is the same verdict as a 400: neither can answer with
// current data, and leaving riders with no plan is the worse outcome.
func TestPlannerHealthTreatsUnreachableAsUnhealthy(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	serverURL := server.URL
	server.Close()

	monitor := NewPlannerHealthMonitor(NewMotisHealthClient(serverURL))
	monitor.check(t.Context())
	monitor.check(t.Context())
	if monitor.UseMotis() {
		t.Fatal("an unreachable MOTIS is still being used")
	}
	if status := monitor.Status(); status.Backend != _plannerTDX {
		t.Errorf("backend = %q, want tdx", status.Backend)
	}
}

// MAAS_BACKEND=tdx builds no MOTIS client at all. The monitor must then report
// a pinned backend rather than an opinion about a service nobody is watching.
func TestPlannerHealthReportsPinnedWithoutAClient(t *testing.T) {
	monitor := NewPlannerHealthMonitor(nil)
	monitor.Start(t.Context())
	if monitor.UseMotis() {
		t.Fatal("a monitor with no client claimed MOTIS is live")
	}
	status := monitor.Status()
	if status.Backend != _plannerTDX || !status.Pinned {
		t.Fatalf("status = %+v, want a pinned tdx backend", status)
	}
}

// The whole point of the endpoint: the app must be able to tell which options
// it may offer. A TDX backend must not advertise MOTIS-only capabilities.
func TestPlannerStatusAdvertisesOnlyWhatTheLiveBackendHonours(t *testing.T) {
	gin.SetMode(gin.TestMode)

	read := func(monitor *PlannerHealthMonitor) plannerStatusBody {
		t.Helper()
		engine := gin.New()
		RegisterPlannerStatusRoutes(engine, monitor, func(c *gin.Context) { c.Next() })
		recorder := httptest.NewRecorder()
		engine.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, PlannerStatusPath, nil))
		if recorder.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", recorder.Code)
		}
		var body plannerStatusBody
		if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		return body
	}

	pinned := read(NewPlannerHealthMonitor(nil))
	if pinned.Backend != _plannerTDX {
		t.Errorf("pinned backend = %q", pinned.Backend)
	}
	for _, capability := range pinned.Capabilities {
		if capability == _capWheelchair || capability == _capMaxTransfers {
			t.Errorf("tdx advertised the MOTIS-only capability %q", capability)
		}
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"rt":true,"gbfs":true}`))
	}))
	defer server.Close()
	live := NewPlannerHealthMonitor(NewMotisHealthClient(server.URL))
	live.check(t.Context())
	motis := read(live)
	if motis.Backend != _plannerMotis {
		t.Fatalf("live backend = %q, want motis", motis.Backend)
	}
	if len(motis.Capabilities) <= len(pinned.Capabilities) {
		t.Fatal("MOTIS advertised no more capabilities than TDX")
	}
	// The shared five lead in the same order for both, so the options sheet
	// does not reshuffle under the rider when the backend changes.
	for i, capability := range pinned.Capabilities {
		if motis.Capabilities[i] != capability {
			t.Fatalf("capability %d = %q under motis, %q under tdx", i, motis.Capabilities[i], capability)
		}
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
