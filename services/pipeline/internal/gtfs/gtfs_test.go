package gtfs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPruneGTFSFeeds covers the retention rule: the newest builds survive, older
// ones go, and nothing else in the directory is touched. Deleting the wrong file
// here would take out the feed a planner is actively reading.
func TestPruneGTFSFeeds(t *testing.T) {
	dir := t.TempDir()
	names := []string{
		"gtfs-20260728-0345.zip",
		"gtfs-20260729-0345.zip",
		"gtfs-20260730-0345.zip",
		"gtfs-20260731-0345.zip",
		"gtfs-20260801-0345.zip",
	}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("z"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Neither of these is a dated build and neither may be pruned: one is the
	// stable name a planner polls, the other is unrelated.
	for _, name := range []string{"gtfs.zip", "notes.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("k"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := pruneGTFSFeeds(dir, 3); err != nil {
		t.Fatalf("prune: %v", err)
	}

	got := map[string]bool{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		got[entry.Name()] = true
	}
	want := []string{
		"gtfs-20260801-0345.zip",
		"gtfs-20260731-0345.zip",
		"gtfs-20260730-0345.zip",
		"gtfs.zip",
		"notes.txt",
	}
	for _, name := range want {
		if !got[name] {
			t.Errorf("%s was pruned, want kept", name)
		}
	}
	for _, name := range []string{"gtfs-20260729-0345.zip", "gtfs-20260728-0345.zip"} {
		if got[name] {
			t.Errorf("%s survived, want pruned", name)
		}
	}
}

func TestPruneGTFSFeedsKeepsEverythingUnderLimit(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "gtfs-20260801-0345.zip"), []byte("z"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := pruneGTFSFeeds(dir, 3); err != nil {
		t.Fatalf("prune: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "gtfs-20260801-0345.zip")); err != nil {
		t.Errorf("sole feed was pruned: %v", err)
	}
}

// TestLinkLatestGTFSReplaces asserts the stable name can be repointed at a new
// build. os.Symlink refuses an existing path, so this is the case that would
// break on the second night if the rename dance were wrong.
func TestLinkLatestGTFSReplaces(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"gtfs-20260731-0345.zip", "gtfs-20260801-0345.zip"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, target := range []string{"gtfs-20260731-0345.zip", "gtfs-20260801-0345.zip"} {
		if err := linkLatestGTFS(dir, target); err != nil {
			t.Fatalf("link %s: %v", target, err)
		}
		body, err := os.ReadFile(filepath.Join(dir, _gtfsLatestName))
		if err != nil {
			t.Fatalf("read latest after linking %s: %v", target, err)
		}
		if string(body) != target {
			t.Errorf("latest resolves to %q, want %q", body, target)
		}
	}
	// The temporary link must not survive, or the next prune reports on it.
	if _, err := os.Lstat(filepath.Join(dir, ".gtfs.zip.link")); !os.IsNotExist(err) {
		t.Errorf("temporary link left behind (err=%v)", err)
	}
}

// TestGTFSFilesAreWellFormed guards the two mistakes that are invisible until a
// nightly run fails: a file whose statement is empty, and a statement that
// already carries its own COPY wrapper (the builder adds one).
func TestGTFSFilesAreWellFormed(t *testing.T) {
	seen := map[string]bool{}
	for _, file := range gtfsFiles("20260801-0345") {
		if !strings.HasSuffix(file.name, ".txt") {
			t.Errorf("%s: GTFS members are .txt", file.name)
		}
		if seen[file.name] {
			t.Errorf("%s: listed twice; the zip would carry two entries of that name", file.name)
		}
		seen[file.name] = true
		trimmed := strings.TrimSpace(file.sql)
		if trimmed == "" {
			t.Errorf("%s: empty statement", file.name)
			continue
		}
		if strings.HasPrefix(strings.ToUpper(trimmed), "COPY") {
			t.Errorf("%s: statement wraps itself in COPY; writeGTFSArchive adds it", file.name)
		}
	}
	for _, required := range []string{"agency.txt", "stops.txt", "routes.txt", "feed_info.txt"} {
		if !seen[required] {
			t.Errorf("%s missing: GTFS requires it", required)
		}
	}
}

// TestGTFSFeedInfoQuotesVersion asserts the interpolated version is quoted.
// COPY takes no bind parameters, so this is the one value in the feed that is
// concatenated into SQL rather than bound.
func TestGTFSFeedInfoQuotesVersion(t *testing.T) {
	got := gtfsFeedInfoSQL("20260801-0345")
	if !strings.Contains(got, "'20260801-0345' AS feed_version") {
		t.Errorf("version not quoted into the statement:\n%s", got)
	}
	if quoted := gtfsFeedInfoSQL("it's"); !strings.Contains(quoted, "'it''s'") {
		t.Errorf("embedded quote not escaped:\n%s", quoted)
	}
}
