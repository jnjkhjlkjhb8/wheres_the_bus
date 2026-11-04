package maas

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/go-resty/resty/v2"
	"go.uber.org/zap"
)

const (
	_motisHealthPath = "/api/v1/health"
	// _plannerHealthInterval is how often MOTIS is asked. Its own feed poll is
	// 60s (motis/config.yml), so checking faster than this only produces the
	// same answer more often.
	_plannerHealthInterval = 30 * time.Second
	// _plannerHealthTimeout bounds one check. Generous relative to the endpoint,
	// which reads two booleans out of memory, because a slow answer here must
	// not itself be read as a failure.
	_plannerHealthTimeout   = 5 * time.Second
	_plannerHealthThreshold = 2
)

// PlannerStatus is one observation of the planner, as /api/planner reports it.
type PlannerStatus struct {
	// Backend is always motis; the app, including older builds, reads it.
	Backend string `json:"backend"`
	// Healthy is MOTIS's own verdict: has it completed an update cycle over
	// every configured feed. Informational: plan requests go to MOTIS either way.
	Healthy bool `json:"healthy"`
	// Realtime and Bikeshare are the two feeds that verdict is composed of, so
	// a degraded state says which half is degraded.
	Realtime  bool `json:"realtime"`
	Bikeshare bool `json:"bikeshare"`
	// CheckedAt is when the last check completed; ChangedAt is when Backend
	// last changed. Both are RFC 3339, or empty before the first check.
	CheckedAt string `json:"checkedAt,omitempty"`
	ChangedAt string `json:"changedAt,omitempty"`
	// Reason is why the backend is what it is, in one line, for an operator
	// reading /api/planner at 3am.
	Reason string `json:"reason"`
}

type PlannerHealthMonitor struct {
	client    *resty.Client
	interval  time.Duration
	threshold int
	now       func() time.Time

	mu sync.RWMutex
	// healthy starts true: this exists to detect degradation, not to gate
	// startup. Start runs one check immediately, so the optimistic window is a
	// single request wide.
	healthy   bool
	realtime  bool
	bikeshare bool
	checkedAt time.Time
	changedAt time.Time
	reason    string
	// agreeing counts consecutive checks that disagree with the current state,
	// and resets whenever one agrees. The state flips at threshold.
	agreeing int
}

// NewPlannerHealthMonitor builds the monitor over a MOTIS health client.
func NewPlannerHealthMonitor(client *resty.Client) *PlannerHealthMonitor {
	return &PlannerHealthMonitor{
		client:    client,
		interval:  _plannerHealthInterval,
		threshold: _plannerHealthThreshold,
		now:       time.Now,
		healthy:   true,
		reason:    "no health check has completed yet",
	}
}

// NewMotisHealthClient builds the HTTP client the monitor polls with. Separate
// from the planning client so a plan-sized timeout cannot make a health check
// look like a failure, and the reverse.
func NewMotisHealthClient(baseURL string) *resty.Client {
	return resty.New().SetBaseURL(baseURL).SetTimeout(_plannerHealthTimeout)
}

// Start runs one check immediately, then on the interval until ctx is done. It
// returns after the first check so the router's first request already has a
// real answer rather than the optimistic default.
func (m *PlannerHealthMonitor) Start(ctx context.Context) {
	m.check(ctx)
	go m.poll(ctx)
}

func (m *PlannerHealthMonitor) poll(ctx context.Context) {
	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.check(ctx)
		}
	}
}

// motisHealthResponse is what /api/v1/health returns. Both fields are present
// on a 400 as well as a 200, which is what lets a degraded state name the half
// that is degraded.
type motisHealthResponse struct {
	RT   bool `json:"rt"`
	GBFS bool `json:"gbfs"`
}

// check performs one observation. An unreachable MOTIS counts as unhealthy for
// the same reason a 400 does: both mean it cannot answer with current data.
func (m *PlannerHealthMonitor) check(ctx context.Context) {
	var body motisHealthResponse
	resp, err := m.client.R().SetContext(ctx).SetResult(&body).SetError(&body).Get(_motisHealthPath)
	if err != nil {
		m.observe(false, body, "MOTIS is unreachable: "+err.Error())
		return
	}
	m.observeResponse(resp, body)
}

func (m *PlannerHealthMonitor) observeResponse(resp *resty.Response, body motisHealthResponse) {
	if resp.StatusCode() == http.StatusBadRequest {
		m.observe(false, body, "MOTIS has not completed an update cycle over every feed"+describeFeeds(body))
		return
	}
	if !resp.IsSuccess() {
		m.observe(false, body, "MOTIS health returned "+resp.Status())
		return
	}
	m.observe(true, body, "MOTIS has consumed every configured feed")
}

func describeFeeds(body motisHealthResponse) string {
	return map[motisHealthResponse]string{
		{RT: false, GBFS: false}: " (realtime and bikeshare both stale)",
		{RT: false, GBFS: true}:  " (realtime stale)",
		{RT: true, GBFS: false}:  " (bikeshare stale)",
	}[body]
}

// observe folds one check into the state, flipping the live backend only once
// threshold consecutive checks have disagreed with it.
func (m *PlannerHealthMonitor) observe(healthy bool, body motisHealthResponse, reason string) {
	m.mu.Lock()
	m.checkedAt = m.now()
	m.realtime = body.RT
	m.bikeshare = body.GBFS
	if healthy == m.healthy {
		m.agreeing = 0
		m.reason = reason
		m.mu.Unlock()
		return
	}
	m.agreeing++
	if m.agreeing < m.threshold {
		m.mu.Unlock()
		return
	}
	m.healthy = healthy
	m.agreeing = 0
	m.changedAt = m.checkedAt
	m.reason = reason
	m.mu.Unlock()

	// Logged outside the lock, and at Error level on the way down, so a MOTIS
	// with stale feeds is not discoverable only by reading /api/planner.
	if healthy {
		zap.S().Warnw("planner health restored",
			"component", "planner", "action", "health", "event", "health_restored",
			"reason", reason)
		return
	}
	zap.S().Errorw("planner unhealthy",
		"component", "planner", "action", "health", "event", "health_degraded",
		"reason", reason)
}

// Status renders the current observation.
func (m *PlannerHealthMonitor) Status() PlannerStatus {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.statusLocked()
}

func (m *PlannerHealthMonitor) statusLocked() PlannerStatus {
	status := PlannerStatus{
		Backend:   "motis",
		Healthy:   m.healthy,
		Realtime:  m.realtime,
		Bikeshare: m.bikeshare,
		Reason:    m.reason,
	}
	status.CheckedAt = observedTime(m.checkedAt)
	status.ChangedAt = observedTime(m.changedAt)
	return status
}

func observedTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.Format(time.RFC3339)
}
