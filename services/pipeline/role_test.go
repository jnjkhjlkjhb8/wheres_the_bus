package main

import (
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
)

// eta/etl must not resolve to the legacy prod mode.

func TestDBSinceFallbackAllowed(t *testing.T) {
	defer func() { raw.DumpEnabled = false }()
	raw.DumpEnabled = true
	if raw.SinceFallbackAllowed() {
		t.Error("ingestor mode must NOT fall back to dbSince (would 304 an empty raw_tdx)")
	}
	raw.DumpEnabled = false
	if !raw.SinceFallbackAllowed() {
		t.Error("legacy prod must allow dbSince fallback")
	}
}
