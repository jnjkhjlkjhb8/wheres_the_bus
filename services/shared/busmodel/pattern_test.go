package busmodel

import (
	"strings"
	"testing"
)

// Realtime runs LoadedPatternSQL as a role with no USAGE on raw_tdx.
func TestLoadedPatternSQLAvoidsRawSchema(t *testing.T) {
	if strings.Contains(LoadedPatternSQL, "raw_tdx") {
		t.Fatal("LoadedPatternSQL reads raw_tdx; realtime has no access to that schema")
	}
}
