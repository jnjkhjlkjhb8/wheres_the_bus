package bus

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

// fetchLog records every fetch name a run makes and fails each fetch, so a
// city run stops right after its first upstream call. hook runs once, inside
// the first fetch.
type fetchLog struct {
	mu    sync.Mutex
	names []string
	hook  func(name string)
}

func (l *fetchLog) fetch(_ context.Context, _, name string) (*shared.TDXFetch, error) {
	l.mu.Lock()
	l.names = append(l.names, name)
	hook := l.hook
	l.hook = nil
	l.mu.Unlock()
	if hook != nil {
		hook(name)
	}
	return nil, errors.New("upstream unavailable")
}

func (l *fetchLog) count(city string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for _, name := range l.names {
		if name == "bus_EstimatedTimeOfArrival"+city {
			n++
		}
	}
	return n
}

// seedBusStops serves city's stops from the static cache, so a run reaches the
// fetch without a database.
func seedBusStops(t *testing.T, city string) {
	t.Helper()
	prefix := busmodel.CityPrefix[city]
	predict.StoreStaticMapIn(predict.StaticMapCache(), prefix, []busmodel.StationMap{{SubRouteUID: prefix + "1", StopUID: "S1"}}, "", time.Now())
	t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
}

func demandSink(cities ...string) *captureLiveSink {
	sink := &captureLiveSink{strings: map[string]string{}}
	for _, city := range cities {
		sink.strings[shared.LiveDemandKey("bus_eta", city)] = "1"
	}
	return sink
}

// TestBusEtaTickFetchesOnlyWatchedCities: a city without demand makes no fetch
// and gets no TTL refresh, so its live keys expire.
func TestBusEtaTickFetchesOnlyWatchedCities(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	seedBusStops(t, "Tainan")
	seedBusStops(t, "YilanCounty")
	sink := demandSink("Tainan")
	log := &fetchLog{}
	_ = Eta(t.Context(), log.fetch, sink, nil, nil, pipeline.NewLiveFetchGuard())
	for _, name := range log.names {
		if !strings.HasSuffix(name, "Tainan") {
			t.Fatalf("unwatched city fetched: %v", log.names)
		}
	}
	if log.count("Tainan") != 1 {
		t.Fatalf("watched city fetches=%v", log.names)
	}
	if len(sink.refresh) != 0 || len(sink.sets) != 0 || len(sink.expires) != 0 {
		t.Fatalf("tick wrote refresh=%v sets=%v expires=%v", sink.refresh, sink.sets, sink.expires)
	}
}

// TestBusEtaSnapshotTickHonorsDemandGate: collecting history is never a reason
// to fetch a city, so a snapshot tick skips a city without demand.
func TestBusEtaSnapshotTickHonorsDemandGate(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	seedBusStops(t, "YilanCounty")
	sink := demandSink()
	log := &fetchLog{}
	snapshot := busLiveJob{
		sink: sink, demand: busDemand{dataset: "bus_eta"}, snapshot: true, now: time.Now,
		store: &fakeBusEtaStore{}, fetch: log.fetch,
	}
	if err := snapshot.runDemandCity(t.Context(), "YilanCounty"); err != nil {
		t.Fatalf("runDemandCity = %v", err)
	}
	if len(log.names) != 0 || len(sink.refresh) != 0 {
		t.Fatalf("snapshot tick fetched %v refreshed %v", log.names, sink.refresh)
	}
	// busEtaFast carries no dataset, so it is never gated at all.
	fast := busLiveJob{sink: sink}
	if release, ok := fast.claimCity(t.Context(), "YilanCounty"); !ok {
		t.Fatal("the ungated Data.taipei job was gated")
	} else {
		release()
	}
}

func TestBusEtaCityWakeRunsExactlyThatSlowCity(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	core, logs := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	seedBusStops(t, "Tainan")
	seedBusStops(t, "Kaohsiung")
	log := &fetchLog{}
	_ = EtaCity(t.Context(), "Tainan", log.fetch, demandSink("Tainan", "Kaohsiung"), nil, nil, pipeline.NewLiveFetchGuard())
	if len(log.names) == 0 || log.count("Tainan") != 1 {
		t.Fatalf("wake fetches=%v", log.names)
	}
	// A wake never samples history: the tick after it in the same window would
	// sample the city again.
	starts := logs.FilterMessage("start").FilterField(zap.String("component", "bus_eta")).All()
	if len(starts) != 1 || starts[0].ContextMap()["snapshot"] != false {
		t.Fatalf("wake start logs=%v", starts)
	}
	for _, name := range log.names {
		if !strings.HasSuffix(name, "Tainan") {
			t.Fatalf("wake fetched another city: %v", log.names)
		}
	}
}

// TestBusEtaCityWakeIgnoresDataTaipeiAndUnknownCities: Taipei and New Taipei
// have demand keys too, but their buses must never cost a TDX fetch.
func TestBusEtaCityWakeIgnoresDataTaipeiAndUnknownCities(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	cities := []string{"Taipei", "NewTaipei", "Atlantis"}
	for _, city := range cities {
		if busmodel.CityPrefix[city] != "" {
			seedBusStops(t, city)
		}
	}
	log := &fetchLog{}
	for _, city := range cities {
		if err := EtaCity(t.Context(), city, log.fetch, demandSink(cities...), nil, nil, pipeline.NewLiveFetchGuard()); err != nil {
			t.Fatalf("%s: %v", city, err)
		}
	}
	if len(log.names) != 0 {
		t.Fatalf("wakes fetched %v", log.names)
	}
}

// TestBusWakeAndTickFetchACityOnce: a tick arriving while the wake is still
// fetching, or just after it, leaves the city alone.
func TestBusWakeAndTickFetchACityOnce(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	seedBusStops(t, "Tainan")
	sink := demandSink("Tainan")
	guard := pipeline.NewLiveFetchGuard()
	log := &fetchLog{}
	log.hook = func(string) {
		_ = Eta(context.Background(), log.fetch, sink, nil, nil, guard)
	}
	_ = EtaCity(t.Context(), "Tainan", log.fetch, sink, nil, nil, guard)
	_ = Eta(t.Context(), log.fetch, sink, nil, nil, guard)
	if got := log.count("Tainan"); got != 1 {
		t.Fatalf("Tainan fetched %d times, want 1: %v", got, log.names)
	}
}
