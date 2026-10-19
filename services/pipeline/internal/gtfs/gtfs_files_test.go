package gtfs

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestPublishedGTFSFileHasDurableContentAndReadablePermissions(t *testing.T) {
	dir := t.TempDir()
	temp, err := os.CreateTemp(dir, ".feed-*")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := temp.WriteString("feed contents"); err != nil {
		t.Fatal(err)
	}
	final := filepath.Join(dir, "gtfs.zip")
	if err := publishGTFSFile(temp, final); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(final)
	if err != nil || string(body) != "feed contents" {
		t.Fatalf("published bytes = %q, %v", body, err)
	}
	info, err := os.Stat(final)
	if err != nil || info.Mode().Perm() != 0o644 {
		t.Fatalf("permissions = %v, %v", info, err)
	}
	if err := publishGTFSFile(temp, final); err == nil {
		t.Fatal("closed temporary file published")
	}
	other, err := os.CreateTemp(dir, ".feed-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = other.Close() })
	if err := publishGTFSFile(other, filepath.Join(dir, "missing", "gtfs.zip")); err == nil {
		t.Fatal("missing destination directory succeeded")
	}
}

func TestPruneRunFilesProtectsPublishedYoungAndIncompleteExports(t *testing.T) {
	root := t.TempDir()
	for _, test := range []struct {
		id  string
		seq int64
		age time.Duration
	}{
		{"old", 1, 48 * time.Hour}, {"previous", 2, 48 * time.Hour},
		{"active", 3, 48 * time.Hour}, {"young", 1, 0},
	} {
		dir := RunDir(root, test.id)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := writeManifest(dir, Manifest{RunID: test.id, BuildSeq: test.seq}); err != nil {
			t.Fatal(err)
		}
		at := time.Now().Add(-test.age)
		if err := os.Chtimes(dir, at, at); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(RunDir(root, "incomplete"), 0o755); err != nil {
		t.Fatal(err)
	}
	errs, err := pruneGTFSRunFiles(root, 2, time.Hour)
	if err != nil || len(errs) != 0 {
		t.Fatalf("prune = %v, %v", errs, err)
	}
	if _, err := os.Stat(RunDir(root, "old")); !os.IsNotExist(err) {
		t.Fatalf("old run survives: %v", err)
	}
	for _, id := range []string{"previous", "active", "young", "incomplete"} {
		if _, err := os.Stat(RunDir(root, id)); err != nil {
			t.Fatalf("protected %s removed: %v", id, err)
		}
	}
	if _, err := pruneGTFSRunFiles(t.TempDir(), 2, time.Hour); err == nil {
		t.Fatal("missing runs directory succeeded")
	}
}

type rejectedGTFSWriter struct{}

func (rejectedGTFSWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestGTFSArchiveWritesEveryRequiredFileAndCleansFailedBuild(t *testing.T) {
	pool := gtfsTestPool(t)
	dir := t.TempDir()
	file, _, err := buildGTFSFeed(context.Background(), pool, dir, time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	assertLink(t, dir, _gtfsLatestName, filepath.Base(file))
	archive, err := zip.OpenReader(file)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = archive.Close() })
	entries := map[string]bool{}
	for _, file := range archive.File {
		entries[file.Name] = true
	}
	for _, required := range gtfsFiles("20261010-1200") {
		if !entries[required.name] {
			t.Fatalf("missing %s", required.name)
		}
	}
	if _, err := writeGTFSArchive(context.Background(), pool, rejectedGTFSWriter{}, "failure"); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("writer failure = %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := buildGTFSFeed(ctx, pool, t.TempDir(), time.Now()); err == nil {
		t.Fatal("cancelled build succeeded")
	}
}

type failingGTFSExec struct {
	pgx.Tx
	prefix  string
	failure error
	calls   []string
}

func (tx *failingGTFSExec) Exec(_ context.Context, sql string, _ ...any) (pgconn.CommandTag, error) {
	tx.calls = append(tx.calls, sql)
	if strings.HasPrefix(sql, tx.prefix) {
		return pgconn.CommandTag{}, tx.failure
	}
	return pgconn.NewCommandTag("CREATE TABLE"), nil
}

func TestTempTableMaterializationStopsAtEveryFailedStage(t *testing.T) {
	want := errors.New("transaction stage failed")
	for _, test := range []struct {
		data   bool
		prefix string
	}{
		{false, "CREATE TEMP TABLE"}, {true, "CREATE TEMP TABLE"},
		{true, "CREATE INDEX"}, {true, "ANALYZE"},
	} {
		t.Run(fmt.Sprintf("%t-%s", test.data, test.prefix), func(t *testing.T) {
			tx := &failingGTFSExec{prefix: test.prefix, failure: want}
			if err := createGTFSTempTables(context.Background(), tx, test.data); !errors.Is(err, want) {
				t.Fatalf("error = %v", err)
			}
			if !strings.HasPrefix(tx.calls[len(tx.calls)-1], test.prefix) {
				t.Fatalf("work continued after failure: %v", tx.calls)
			}
		})
	}
}
