package pipeline

import (
	"context"
	"sync"
	"time"

	"go.uber.org/zap"
)

// LiveFetchGuard keeps a demand wake and a cron tick from fetching the same
// live partition twice. Process memory is enough because realtime runs as a
// single replica; a second replica would need a claim shared through Redis.
type LiveFetchGuard struct {
	mu      sync.Mutex
	fetches map[string]liveFetch
	now     func() time.Time
}

type liveFetch struct {
	inFlight bool
	started  time.Time
}

// _liveFetchSpacing is shorter than every live cadence, so it only ever skips
// the second of a wake and a tick, never one tick after another.
const _liveFetchSpacing = 10 * time.Second

// NewLiveFetchGuard returns an empty guard to share between the cron ticks and
// the wake path.
func NewLiveFetchGuard() *LiveFetchGuard {
	return &LiveFetchGuard{fetches: make(map[string]liveFetch), now: time.Now}
}

// Claim marks dataset's partition as being fetched. It fails while another
// fetch of the partition is in flight or started within _liveFetchSpacing;
// otherwise the caller must call release when its fetch ends. A nil guard
// claims everything, for one-shot runs that share nothing.
func (g *LiveFetchGuard) Claim(dataset, partition string) (release func(), ok bool) {
	if g == nil {
		return func() {}, true
	}
	return g.claim(dataset + ":" + partition)
}

func (g *LiveFetchGuard) claim(key string) (func(), bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if g.busy(key, now) {
		zap.S().Infow("skip", "component", "live", "action", "claim", "event", "skip", "partition", key, "reason", "fetched_recently")
		return nil, false
	}
	g.fetches[key] = liveFetch{inFlight: true, started: now}
	return func() { g.finish(key) }, true
}

func (g *LiveFetchGuard) busy(key string, now time.Time) bool {
	last := g.fetches[key]
	return last.inFlight || now.Sub(last.started) < _liveFetchSpacing
}

func (g *LiveFetchGuard) finish(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	last := g.fetches[key]
	last.inFlight = false
	g.fetches[key] = last
}

// ClaimLiveDemand gates dataset's partition on live demand, then claims it on
// guard. The gate runs first so a tick that found no demand leaves no claim to
// block the wake that follows it.
func ClaimLiveDemand(ctx context.Context, sink LiveSink, guard *LiveFetchGuard, dataset, partition string) (release func(), ok bool) {
	if !LiveDemandGate(ctx, sink, dataset, partition) {
		return nil, false
	}
	return guard.Claim(dataset, partition)
}
