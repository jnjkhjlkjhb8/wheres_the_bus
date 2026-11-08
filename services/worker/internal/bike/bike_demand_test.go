package bike

import (
	"context"
	"sync"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

// bikeFetchLog records every fetch name and answers each with a 304. hook runs
// once, inside the first fetch.
type bikeFetchLog struct {
	mu    sync.Mutex
	names []string
	hook  func()
}

func (l *bikeFetchLog) fetch(_ context.Context, _, name string) (*shared.TDXFetch, error) {
	l.mu.Lock()
	l.names = append(l.names, name)
	hook := l.hook
	l.hook = nil
	l.mu.Unlock()
	if hook != nil {
		hook()
	}
	return &shared.TDXFetch{Modified: false}, nil
}

func bikeDemandSink(cities ...string) *captureLiveSink {
	owner := shared.LiveOwnedKeysKey("bike", "Taipei")
	sink := &captureLiveSink{
		strings: map[string]string{},
		owned:   map[string][]string{owner: {shared.BikeAvailabilityKey("TPE-1")}},
	}
	for _, city := range cities {
		sink.strings[shared.LiveDemandKey("bike", city)] = "1"
	}
	return sink
}

// TestBikeTickWithoutDemandFetchesAndRefreshesNothing: a city nobody watches is
// left alone, so its owned keys expire instead of being re-armed.
func TestBikeTickWithoutDemandFetchesAndRefreshesNothing(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	sink := bikeDemandSink()
	log := &bikeFetchLog{}
	if err := Eta(t.Context(), log.fetch, sink, nil, pipeline.NewLiveFetchGuard()); err != nil {
		t.Fatal(err)
	}
	if len(log.names) != 0 || len(sink.refresh) != 0 || len(sink.expires) != 0 || len(sink.contexts) != 0 {
		t.Fatalf("fetches=%v refresh=%v expires=%v execs=%d", log.names, sink.refresh, sink.expires, len(sink.contexts))
	}
}

func TestBikeTickFetchesOnlyWatchedCities(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	log := &bikeFetchLog{}
	if err := Eta(t.Context(), log.fetch, bikeDemandSink("Taichung"), nil, pipeline.NewLiveFetchGuard()); err != nil {
		t.Fatal(err)
	}
	if len(log.names) != 1 || log.names[0] != "bike_availabilityTaichung" {
		t.Fatalf("fetches=%v", log.names)
	}
}

func TestBikeCityWakeRunsOnlyThatServedCity(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	sink := bikeDemandSink("Taichung", "Kaohsiung", "YilanCounty", "Atlantis")
	log := &bikeFetchLog{}
	for _, city := range []string{"Taichung", "YilanCounty", "Atlantis"} {
		if err := EtaCity(t.Context(), city, log.fetch, sink, nil, pipeline.NewLiveFetchGuard()); err != nil {
			t.Fatalf("%s: %v", city, err)
		}
	}
	if len(log.names) != 1 || log.names[0] != "bike_availabilityTaichung" {
		t.Fatalf("fetches=%v", log.names)
	}
}

// TestBikeWakeAndTickFetchACityOnce: a tick that lands while the wake is still
// fetching, or just after it, skips the city.
func TestBikeWakeAndTickFetchACityOnce(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	sink := bikeDemandSink("Taichung")
	guard := pipeline.NewLiveFetchGuard()
	log := &bikeFetchLog{}
	log.hook = func() { _ = Eta(context.Background(), log.fetch, sink, nil, guard) }
	if err := EtaCity(t.Context(), "Taichung", log.fetch, sink, nil, guard); err != nil {
		t.Fatal(err)
	}
	if err := Eta(t.Context(), log.fetch, sink, nil, guard); err != nil {
		t.Fatal(err)
	}
	if len(log.names) != 1 {
		t.Fatalf("fetches=%v, want one", log.names)
	}
}
