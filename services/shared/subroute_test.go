package shared

import "testing"

func TestCanonicalSubroute(t *testing.T) {
	tests := []struct {
		name    string
		city    string
		uid     string
		inDir   uint8
		wantUID string
		wantDir uint8
	}{
		{"intercity 01 suffix", "InterCity", "THB902301", 9, "THB9023", 0},
		{"intercity 02 suffix", "InterCity", "THB902302", 9, "THB9023", 1},
		// Direction comes off the UID, not the caller's field: TDX's own Route
		// dataset agrees with the suffix on every InterCity subroute, and a feed
		// that omits Direction (or sends 255) must not win over the UID.
		{"intercity branch A1 is outbound", "InterCity", "THB9023A1", 3, "THB9023A", 0},
		{"intercity branch A2 is inbound", "InterCity", "THB9023A2", 3, "THB9023A", 1},
		{"intercity branch B2 suffix", "InterCity", "THB9023B2", 255, "THB9023B", 1},
		// No main/branch + direction suffix at all: the UID is a bare route code
		// and stripping its last character invents one nothing else publishes.
		{"intercity bare route code", "InterCity", "THB0968", 1, "THB0968", 1},
		// Canonicalizing an already-canonical UID is a no-op, so a second pass
		// cannot strip a second character.
		{"intercity canonical main route is idempotent", "InterCity", "THB9023", 0, "THB9023", 0},
		{"intercity canonical branch is idempotent", "InterCity", "THB9023A", 1, "THB9023A", 1},
		{"intercity bare route code odd length", "InterCity", "THB123", 0, "THB123", 0},
		{"intercity digit before direction", "InterCity", "THB17031", 1, "THB17031", 1},
		{"intercity lowercase is not a branch", "InterCity", "THB9023a1", 1, "THB9023a1", 1},
		{"non-intercity passthrough", "Taipei", "TPE1234", 1, "TPE1234", 1},
		{"intercity short uid safe", "InterCity", "X", 1, "X", 1},
		{"intercity empty uid safe", "InterCity", "", 0, "", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotUID, gotDir := CanonicalSubroute(tt.city, tt.uid, tt.inDir)
			if gotUID != tt.wantUID || gotDir != tt.wantDir {
				t.Fatalf("CanonicalSubroute(%q, %q, %d) = (%q, %d), want (%q, %d)",
					tt.city, tt.uid, tt.inDir, gotUID, gotDir, tt.wantUID, tt.wantDir)
			}
		})
	}
}
