package bus

import (
	"context"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestBusEtaSnapshotTickIgnoresDemandGate(t *testing.T) {
	ctx := context.Background()
	sink := &captureLiveSink{}

	// Go cold first, so the gate alone would skip every later tick.
	if !pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
		t.Fatal("first tick was skipped")
	}
	if pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
		t.Fatal("second tick was not skipped, so the city is not cold")
	}

	snapshot := busLiveJob{sink: sink, demandDataset: "bus_eta", snapshot: true}
	if !snapshot.shouldRunCity(ctx, "YilanCounty") {
		t.Fatal("a snapshot tick was gated away; bus_eta_history would lose the city")
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
