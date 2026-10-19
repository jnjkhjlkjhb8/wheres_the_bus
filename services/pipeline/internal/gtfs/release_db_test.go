package gtfs

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func releaseTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	admin := gtfsTestPool(t)
	ctx := context.Background()
	schema := fmt.Sprintf("quality_gtfs_release_%d", time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+quoted); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(ctx, "DROP SCHEMA "+quoted+" CASCADE"); err != nil {
			t.Error(err)
		}
	})
	if _, err := admin.Exec(ctx, "CREATE SEQUENCE "+quoted+".static_build_seq"); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"static_release", "gtfs_rt_bus_trip", "gtfs_rt_rail_trip", "gtfs_rt_bus_offset"} {
		if _, err := admin.Exec(ctx, "CREATE TABLE "+quoted+"."+table+" (LIKE public."+table+" INCLUDING ALL)"); err != nil {
			t.Fatal(err)
		}
	}
	config, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestGTFSReleaseExportsHashPublishesMonotonicallyAndPrunesSnapshots(t *testing.T) {
	pool := releaseTestPool(t)
	ctx := context.Background()
	root := t.TempDir()
	if err := Prune(ctx, pool, root, time.Hour); err != nil {
		t.Fatal(err)
	}
	scheduled := filepath.Join(root, "scheduled")
	t.Setenv(_gtfsOutputDirEnv, scheduled)
	RunExport(pool, time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC))
	assertLink(t, scheduled, _gtfsLatestName, "gtfs-20261010-1200.zip")
	first, err := ExportRun(ctx, pool, root, "first", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(RunDir(root, first.RunID), _runFeed))
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(body)
	if first.BuildSeq != 1 || first.GTFSSHA256 != hex.EncodeToString(hash[:]) {
		t.Fatalf("export identity = %+v", first)
	}
	stored, err := ReadManifest(root, first.RunID)
	if err != nil || stored != first {
		t.Fatalf("stored manifest = %+v, %v", stored, err)
	}
	if err := Publish(ctx, pool, root, first); err != nil {
		t.Fatal(err)
	}
	for seq := int64(2); seq <= 3; seq++ {
		m := Manifest{RunID: fmt.Sprintf("run-%d", seq), BuildSeq: seq, GTFSSHA256: "synthetic"}
		if err := os.MkdirAll(RunDir(root, m.RunID), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := writeManifest(RunDir(root, m.RunID), m); err != nil {
			t.Fatal(err)
		}
		if err := Publish(ctx, pool, root, m); err != nil {
			t.Fatal(err)
		}
	}
	if err := Publish(ctx, pool, root, first); !errors.Is(err, ErrStaleRun) {
		t.Fatalf("stale publish = %v", err)
	}
	assertLink(t, root, _activeLink, filepath.Join(_runsDir, "run-3"))
	assertLink(t, root, _previousLink, filepath.Join(_runsDir, "run-2"))
	var count int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM static_release").Scan(&count); err != nil || count != 3 {
		t.Fatalf("release count = %d, %v", count, err)
	}
	for _, id := range []string{"first", "run-2", "run-3", "in-progress"} {
		if _, err := pool.Exec(ctx, "INSERT INTO gtfs_rt_bus_trip VALUES ($1, $2, 0, 'W:1111111')", id, "quality-"+id); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(RunDir(root, "first"), old, old); err != nil {
		t.Fatal(err)
	}
	if err := Prune(ctx, pool, root, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(RunDir(root, "first")); !os.IsNotExist(err) {
		t.Fatalf("expired run remains: %v", err)
	}
	for _, id := range []string{"run-2", "run-3", "in-progress"} {
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM gtfs_rt_bus_trip WHERE run_id = $1", id).Scan(&count); err != nil || count != 1 {
			t.Fatalf("protected %s rows = %d, %v", id, count, err)
		}
	}
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM gtfs_rt_bus_trip WHERE run_id = 'first'").Scan(&count); err != nil || count != 0 {
		t.Fatalf("expired snapshot remains: %d, %v", count, err)
	}
}

func TestGTFSReleaseCancellationAndFilesystemFailuresPreserveState(t *testing.T) {
	pool := releaseTestPool(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	root := t.TempDir()
	if _, err := ExportRun(ctx, pool, root, "cancelled", time.Now()); err == nil {
		t.Fatal("cancelled export succeeded")
	}
	if err := Publish(ctx, pool, root, Manifest{BuildSeq: 1}); err == nil {
		t.Fatal("cancelled publish succeeded")
	}
	if err := Prune(ctx, pool, root, time.Hour); err == nil {
		t.Fatal("cancelled prune succeeded")
	}
	if _, err := os.Stat(RunDir(root, "cancelled")); !os.IsNotExist(err) {
		t.Fatal("cancelled export created a run")
	}
	blocked := filepath.Join(root, "file")
	if err := os.WriteFile(blocked, []byte("occupied"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ExportRun(context.Background(), pool, blocked, "blocked", time.Now()); err == nil {
		t.Fatal("run exported under a file")
	}
	if err := Publish(context.Background(), pool, blocked, Manifest{RunID: "blocked", BuildSeq: 5}); err == nil {
		t.Fatal("publish into a file succeeded")
	}
	var count int
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM static_release").Scan(&count); err != nil || count != 0 {
		t.Fatalf("failed publish recorded release: %d, %v", count, err)
	}
}

func TestGTFSOutputDirectoryAndFailedScheduledExport(t *testing.T) {
	t.Setenv(_gtfsOutputDirEnv, "  ")
	if got := gtfsOutputDir(); got != _gtfsDefaultOutputDir {
		t.Fatalf("default output directory = %q", got)
	}
	blocked := filepath.Join(t.TempDir(), "occupied")
	if err := os.WriteFile(blocked, []byte("occupied"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(_gtfsOutputDirEnv, "  "+blocked+"  ")
	if got := gtfsOutputDir(); got != blocked {
		t.Fatalf("configured output directory = %q", got)
	}
	RunExport(nil, time.Now())
	body, err := os.ReadFile(blocked)
	if err != nil || string(body) != "occupied" {
		t.Fatalf("failed export changed destination: %q, %v", body, err)
	}
}
