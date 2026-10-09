package main

import (
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
)

func TestDatasetRegistryConsistency(t *testing.T) {
	reg := dataset.Registry()

	for _, d := range reg {
		if d.Fetched() && d.LoadKey == "" && d.FoldedInto == "" && !d.ExportOnly {
			t.Errorf("fetched dataset %q has neither a loader, FoldedInto, nor ExportOnly", d.RawTable)
		}
	}

	// ExportOnly is the absence of a loader, not an alternative spelling of one:
	// a table carrying both would be loaded and silently ignored by this file's
	// other invariants.
	for _, d := range reg {
		if d.ExportOnly && (d.LoadKey != "" || d.FoldedInto != "") {
			t.Errorf("ExportOnly dataset %q also has LoadKey %q / FoldedInto %q",
				d.RawTable, d.LoadKey, d.FoldedInto)
		}
	}

	externallyLanded := map[string]bool{
		"bus_dailytimetable/Taipei": true,
	}
	for _, d := range reg {
		if d.LoadKey == "" {
			continue
		}
		if !d.Fetched() {
			t.Errorf("loader dataset %q (LoadKey %q) is not fetched", d.RawTable, d.LoadKey)
		}
		land := map[string]bool{}
		for _, p := range d.Partitions() {
			land[p] = true
		}
		for _, p := range d.LoadPartitions() {
			if !land[p] && !externallyLanded[d.RawTable+"/"+p] {
				t.Errorf("dataset %q loads partition %q that is not landed", d.RawTable, p)
			}
		}
	}

	// Every FoldedInto target names a real standalone loader.
	loadKeys := map[string]bool{}
	for _, d := range reg {
		if d.LoadKey != "" {
			loadKeys[d.LoadKey] = true
		}
	}
	for _, d := range reg {
		if d.FoldedInto != "" && !loadKeys[d.FoldedInto] {
			t.Errorf("dataset %q folds into unknown loader %q", d.RawTable, d.FoldedInto)
		}
	}

	// loaderTransforms and Registry loadKeys are in exact correspondence:
	// no orphan binding, no dataset LoadKey without a transform.
	transforms := loaderTransforms(nil)
	for k := range loadKeys {
		if _, ok := transforms[k]; !ok {
			t.Errorf("dataset LoadKey %q has no loaderTransforms binding", k)
		}
	}
	for k := range transforms {
		if !loadKeys[k] {
			t.Errorf("loaderTransforms key %q has no Registry LoadKey", k)
		}
	}

	// The whitelist is exactly the set of registry tables.
	for _, d := range reg {
		if !raw.TDXTables[d.RawTable] {
			t.Errorf("registry table %q missing from whitelist", d.RawTable)
		}
	}
	if len(raw.TDXTables) != len(reg) {
		t.Errorf("whitelist has %d tables, registry has %d", len(raw.TDXTables), len(reg))
	}
}

// TestLoaderRegistryFoldsOperatorsIntoAtomicBusSnapshot asserts there is only
// one target writer for correlated bus static data. The raw operator dataset is
// still fetched, but it must not get a standalone loader transaction.
func TestLoaderRegistryFoldsOperatorsIntoAtomicBusSnapshot(t *testing.T) {
	for _, spec := range loaderRegistry(nil) {
		if spec.key == "bus_operator" {
			t.Fatal("bus_operator still has a standalone loader transaction")
		}
	}
	for _, dataset := range dataset.Registry() {
		if dataset.RawTable == "bus_operator" {
			if dataset.LoadKey != "" || dataset.FoldedInto != "bus" {
				t.Fatalf("bus_operator LoadKey/FoldedInto = %q/%q, want empty/bus", dataset.LoadKey, dataset.FoldedInto)
			}
			return
		}
	}
	t.Fatal("bus_operator dataset missing")
}

// TestFetchURLsRoundTripToTargets proves the fetch list and the reverse target
// map agree: every landing URL the ingestor builds resolves back through
// raw.DumpTarget to the same table, partition column, and partition value.
func TestFetchURLsRoundTripToTargets(t *testing.T) {
	for _, d := range dataset.Registry() {
		if !d.Fetched() {
			continue
		}
		for _, part := range d.Partitions() {
			url := d.URL(part)
			got, ok := raw.DumpTarget(url)
			if !ok {
				t.Errorf("%s: raw.DumpTarget did not resolve fetched URL", url)
				continue
			}
			want := raw.Target{Table: d.RawTable, PartCol: d.PartCol, PartVal: part}
			if got != want {
				t.Errorf("%s: got %+v, want %+v", url, got, want)
			}
		}
	}
}

// TestBusDatasetsCoverIngestBusAPIs keeps ingestBusAPIs (still used by the
// ingestor fan-out test) in step with the registry's bus datasets.
func TestBusDatasetsCoverIngestBusAPIs(t *testing.T) {
	got := map[string]bool{}
	for _, d := range dataset.Registry() {
		if d.Family == dataset.FamilyBusCity {
			got[d.APISeg] = true
		}
	}
	if len(got) != len(_ingestBusAPIs) {
		t.Fatalf("bus datasets = %d apiSegs, ingestBusAPIs = %d", len(got), len(_ingestBusAPIs))
	}
	for _, api := range _ingestBusAPIs {
		if !got[api] {
			t.Errorf("ingestBusAPIs entry %q has no bus dataset", api)
		}
	}
}
