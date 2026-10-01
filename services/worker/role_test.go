package main

import (
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/raw"
)

func TestResolveRole(t *testing.T) {
	okCases := map[string]appMode{
		"":         _modeLegacyProd,
		"ingestor": _modeIngestor,
		"loader":   _modeLoader,
	}
	for role, want := range okCases {
		got, err := resolveRole(role)
		if err != nil {
			t.Errorf("resolveRole(%q) unexpected error: %v", role, err)
		}
		if got != want {
			t.Errorf("resolveRole(%q) = %v, want %v", role, got, want)
		}
	}
	for _, role := range []string{"eta", "realtime", "etl", "bogus", "INGESTOR", "Ingestor"} {
		if _, err := resolveRole(role); err == nil {
			t.Errorf("resolveRole(%q) expected error, got nil", role)
		}
	}
	// eta/etl must not resolve to the legacy prod mode.
	for _, role := range []string{"eta", "realtime", "etl"} {
		if got, _ := resolveRole(role); got == _modeLegacyProd {
			t.Errorf("resolveRole(%q) must not be modeLegacyProd", role)
		}
	}
}

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
