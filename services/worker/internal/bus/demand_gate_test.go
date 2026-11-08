package bus

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

// TestBusEtaSnapshotTickHonorsDemandGate: collecting history is never a reason
// to fetch a city, so a snapshot tick skips a cold city like any other tick.
func TestBusEtaSnapshotTickHonorsDemandGate(t *testing.T) {
	ctx := context.Background()
	sink := &captureLiveSink{}

	// Go cold first, so the gate alone would skip every later tick.
	if !pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
		t.Fatal("first tick was skipped")
	}
	if pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
		t.Fatal("second tick was not skipped, so the city is not cold")
	}

	// Stops are served so that, were the gate bypassed, the run would reach the
	// fetch rather than stop early.
	prefix := busmodel.CityPrefix["YilanCounty"]
	predict.StaticMapCache().Delete(prefix)
	t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
	var fetched []string
	snapshot := busLiveJob{
		sink: sink, demandDataset: "bus_eta", snapshot: true, now: time.Now,
		store: &fakeBusEtaStore{stops: []busmodel.StationMap{{SubRouteUID: prefix + "1", StopUID: "S1"}}},
		fetch: func(_ context.Context, _, name string) (*shared.TDXFetch, error) {
			fetched = append(fetched, name)
			return nil, errors.New("unexpected fetch")
		},
	}
	if err := snapshot.runDemandCity(ctx, "YilanCounty"); err != nil {
		t.Fatalf("runDemandCity = %v", err)
	}
	if len(fetched) != 0 {
		t.Fatalf("snapshot tick fetched %v for a cold city", fetched)
	}

	// The same job on an ordinary tick is still gated, or the gate saves nothing.
	ordinary := busLiveJob{sink: sink, demandDataset: "bus_eta"}
	if ordinary.shouldRunCity(ctx, "YilanCounty") {
		t.Fatal("a cold city ran on an ordinary tick")
	}

	// busEtaFast carries no dataset, so it is never gated at all.
	fast := busLiveJob{sink: sink}
	if !fast.shouldRunCity(ctx, "YilanCounty") {
		t.Fatal("the ungated Data.taipei job was gated")
	}
}
