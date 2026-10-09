package gtfs

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestSwitchActiveMovesOldActiveToPrevious(t *testing.T) {
	root := t.TempDir()
	if err := switchActive(root, "run-a"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(root, _previousLink)); !os.IsNotExist(err) {
		t.Fatalf("previous exists after the first publish: %v", err)
	}
	if err := switchActive(root, "run-b"); err != nil {
		t.Fatal(err)
	}
	assertLink(t, root, _activeLink, filepath.Join(_runsDir, "run-b"))
	assertLink(t, root, _previousLink, filepath.Join(_runsDir, "run-a"))

	// Republishing the active run must not make it its own previous.
	if err := switchActive(root, "run-b"); err != nil {
		t.Fatal(err)
	}
	assertLink(t, root, _previousLink, filepath.Join(_runsDir, "run-a"))
}

func TestManifestRoundTripAndRunMismatch(t *testing.T) {
	root := t.TempDir()
	want := Manifest{RunID: "run-a", BuildSeq: 7, GTFSSHA256: "abc"}
	dir := RunDir(root, "run-a")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeManifest(dir, want); err != nil {
		t.Fatal(err)
	}
	got, err := ReadManifest(root, "run-a")
	if err != nil || got != want {
		t.Fatalf("ReadManifest = %+v, %v; want %+v", got, err, want)
	}

	// A manifest copied under another run's directory must not publish as that run.
	other := RunDir(root, "run-b")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeManifest(other, want); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadManifest(root, "run-b"); err == nil {
		t.Fatal("ReadManifest accepted a manifest naming another run")
	}
	if _, err := ReadManifest(root, "run-missing"); err == nil {
		t.Fatal("ReadManifest accepted a run that never exported")
	}
}

func assertLink(t *testing.T, root, name, want string) {
	t.Helper()
	got, err := os.Readlink(filepath.Join(root, name))
	if err != nil || got != want {
		t.Fatalf("%s -> %q (%v), want %q", name, got, err, want)
	}
}

// TestSnapshotStatementsPlan checks the GTFS-RT snapshot writes against the
// migrated schema: every column and table they name has to resolve.
func TestSnapshotStatementsPlan(t *testing.T) {
	tx := gtfsTestTx(t, gtfsTestPool(t), false /* withData */)
	for name, stmt := range map[string]string{
		"bus_trip":   _snapshotBusTripSQL,
		"rail_trip":  _snapshotRailTripSQL,
		"bus_offset": _snapshotBusOffsetSQL,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := tx.Exec(context.Background(), "EXPLAIN "+stmt, "run-plan"); err != nil {
				t.Errorf("%s does not plan: %v", name, err)
			}
		})
	}
}
