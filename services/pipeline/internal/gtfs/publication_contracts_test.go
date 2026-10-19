package gtfs

import (
	"archive/zip"
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func seedGTFSContractSnapshots(t *testing.T, pool *pgxpool.Pool, runIDs ...string) {
	t.Helper()
	for _, runID := range runIDs {
		for _, statement := range []string{
			`INSERT INTO gtfs_rt_bus_trip (run_id, trip_id, direction_id, service_id) VALUES ($1, 'old-bus', 0, 'W:1111111')`,
			`INSERT INTO gtfs_rt_rail_trip (run_id, service_date, train_no, trip_id, stations) VALUES ($1, CURRENT_DATE, 'old-rail', 'old-rail', ARRAY['old-station'])`,
			`INSERT INTO gtfs_rt_bus_offset (run_id, sub_route_uid, direction, stop_uid, offset_secs) VALUES ($1, 'old-subroute', 0, 'old-stop', 60)`,
		} {
			if _, err := pool.Exec(t.Context(), statement, runID); err != nil {
				t.Fatalf("seed isolated snapshot %s: %v", runID, err)
			}
		}
	}
}

func installGTFSContractStatementFailure(t *testing.T, pool *pgxpool.Pool, table, operation string) {
	t.Helper()
	if _, err := pool.Exec(t.Context(), `CREATE FUNCTION quality_gtfs_contract_reject() RETURNS trigger LANGUAGE plpgsql AS $$
	BEGIN RAISE EXCEPTION 'quality snapshot fixture rejection' USING ERRCODE = 'P0001'; END $$`); err != nil {
		t.Fatal(err)
	}
	statement := "CREATE TRIGGER quality_gtfs_contract_reject BEFORE " + operation + " ON " + pgx.Identifier{table}.Sanitize() + " FOR EACH STATEMENT EXECUTE FUNCTION quality_gtfs_contract_reject()"
	if _, err := pool.Exec(t.Context(), statement); err != nil {
		t.Fatal(err)
	}
}

func requireGTFSContractDatabaseError(t *testing.T, err error, code string) {
	t.Helper()
	var databaseError *pgconn.PgError
	if !errors.As(err, &databaseError) || databaseError.Code != code {
		t.Fatalf("database error = %v, want PostgreSQL code %s", err, code)
	}
}

func TestGTFSContractSnapshotRetryClearsEveryTableAndProtectsOtherRuns(t *testing.T) {
	pool := releaseTestPool(t)
	seedGTFSContractSnapshots(t, pool, "retry", "foreign")
	if err := writeRTSnapshot(t.Context(), pool, "retry"); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ table, identity string }{
		{table: "gtfs_rt_bus_trip", identity: "trip_id = 'old-bus'"},
		{table: "gtfs_rt_rail_trip", identity: "train_no = 'old-rail'"},
		{table: "gtfs_rt_bus_offset", identity: "stop_uid = 'old-stop'"},
	} {
		var old, foreign int
		query := "SELECT count(*) FILTER (WHERE run_id = 'retry' AND " + tc.identity + "), count(*) FILTER (WHERE run_id = 'foreign') FROM " + pgx.Identifier{tc.table}.Sanitize()
		if err := pool.QueryRow(t.Context(), query).Scan(&old, &foreign); err != nil {
			t.Fatal(err)
		}
		if old != 0 || foreign != 1 {
			t.Fatalf("%s retry rows = %d, foreign rows = %d, want old retry absent and foreign retained", tc.table, old, foreign)
		}
	}
}

func TestGTFSContractSnapshotStatementFailureRollsBackAllThreeTables(t *testing.T) {
	for _, operation := range []string{"DELETE", "INSERT"} {
		t.Run(operation, func(t *testing.T) {
			pool := releaseTestPool(t)
			seedGTFSContractSnapshots(t, pool, "retry", "foreign")
			installGTFSContractStatementFailure(t, pool, "gtfs_rt_rail_trip", operation)
			requireGTFSContractDatabaseError(t, writeRTSnapshot(t.Context(), pool, "retry"), "P0001")
			for _, table := range []string{"gtfs_rt_bus_trip", "gtfs_rt_rail_trip", "gtfs_rt_bus_offset"} {
				var retry, foreign int
				query := "SELECT count(*) FILTER (WHERE run_id = 'retry'), count(*) FILTER (WHERE run_id = 'foreign') FROM " + pgx.Identifier{table}.Sanitize()
				if err := pool.QueryRow(t.Context(), query).Scan(&retry, &foreign); err != nil {
					t.Fatal(err)
				}
				if retry != 1 || foreign != 1 {
					t.Fatalf("%s after failed %s: retry %d, foreign %d, want unchanged snapshots", table, operation, retry, foreign)
				}
			}
		})
	}
}

func TestGTFSContractEqualBuildSequenceCannotReplaceActiveRun(t *testing.T) {
	pool := releaseTestPool(t)
	root := t.TempDir()
	first := Manifest{RunID: "first", BuildSeq: 7, GTFSSHA256: "first-hash"}
	for _, m := range []Manifest{first, {RunID: "equal", BuildSeq: 7, GTFSSHA256: "equal-hash"}} {
		if err := os.MkdirAll(RunDir(root, m.RunID), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := writeManifest(RunDir(root, m.RunID), m); err != nil {
			t.Fatal(err)
		}
	}
	if err := Publish(t.Context(), pool, root, first); err != nil {
		t.Fatal(err)
	}
	err := Publish(t.Context(), pool, root, Manifest{RunID: "equal", BuildSeq: 7, GTFSSHA256: "equal-hash"})
	if !errors.Is(err, ErrStaleRun) {
		t.Fatalf("equal sequence publish error = %v, want ErrStaleRun", err)
	}
	assertLink(t, root, _activeLink, filepath.Join(_runsDir, "first"))
	if _, err := os.Lstat(filepath.Join(root, _previousLink)); !os.IsNotExist(err) {
		t.Fatalf("equal run created previous link: %v", err)
	}
	var count int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM static_release").Scan(&count); err != nil || count != 1 {
		t.Fatalf("release records = %d, %v, want one", count, err)
	}
}

func TestGTFSContractPublicPublishReportsBlockedActiveLinkWithoutRecordingRelease(t *testing.T) {
	pool := releaseTestPool(t)
	root := t.TempDir()
	blocked := filepath.Join(root, _activeLink)
	if err := os.Mkdir(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(blocked, "occupied")
	if err := os.WriteFile(marker, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := Publish(t.Context(), pool, root, Manifest{RunID: "blocked", BuildSeq: 1, GTFSSHA256: "blocked-hash"})
	if err == nil {
		t.Fatal("publish reported success despite a blocked active-link destination")
	}
	var count int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM static_release").Scan(&count); err != nil || count != 0 {
		t.Fatalf("failed link publish recorded %d releases: %v", count, err)
	}
	body, err := os.ReadFile(marker)
	if err != nil || string(body) != "preserve" {
		t.Fatalf("blocked destination changed: %q, %v", body, err)
	}
}

func TestGTFSContractPublicPublishReturnsReleaseStorageFailure(t *testing.T) {
	pool := releaseTestPool(t)
	if _, err := pool.Exec(t.Context(), "ALTER TABLE static_release ADD CONSTRAINT quality_reject_build CHECK (build_seq <> 9)"); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.MkdirAll(RunDir(root, "rejected"), 0o755); err != nil {
		t.Fatal(err)
	}
	err := Publish(t.Context(), pool, root, Manifest{RunID: "rejected", BuildSeq: 9, GTFSSHA256: "rejected-hash"})
	requireGTFSContractDatabaseError(t, err, "23514")
	var count int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM static_release").Scan(&count); err != nil || count != 0 {
		t.Fatalf("rejected build recorded %d releases: %v", count, err)
	}
}

func TestGTFSContractPublicPruneReturnsSnapshotDeletionFailure(t *testing.T) {
	pool := releaseTestPool(t)
	root := t.TempDir()
	for i, id := range []string{"old", "previous", "active"} {
		m := Manifest{RunID: id, BuildSeq: int64(i + 1), GTFSSHA256: id}
		if _, err := pool.Exec(t.Context(), "INSERT INTO static_release (run_id, build_seq, gtfs_sha256) VALUES ($1, $2, $3)", m.RunID, m.BuildSeq, m.GTFSSHA256); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(RunDir(root, id), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := writeManifest(RunDir(root, id), m); err != nil {
			t.Fatal(err)
		}
	}
	seedGTFSContractSnapshots(t, pool, "old", "previous", "active", "unpublished")
	installGTFSContractStatementFailure(t, pool, "gtfs_rt_rail_trip", "DELETE")
	requireGTFSContractDatabaseError(t, Prune(t.Context(), pool, root, 0), "P0001")
	for _, id := range []string{"previous", "active", "unpublished"} {
		for _, table := range []string{"gtfs_rt_bus_trip", "gtfs_rt_rail_trip", "gtfs_rt_bus_offset"} {
			var count int
			if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM "+pgx.Identifier{table}.Sanitize()+" WHERE run_id = $1", id).Scan(&count); err != nil || count != 1 {
				t.Fatalf("protected %s/%s rows = %d, %v", id, table, count, err)
			}
		}
	}
}

func TestGTFSContractRunFeedRejectsBlockedArchiveDestination(t *testing.T) {
	dir := t.TempDir()
	blocked := filepath.Join(dir, _runFeed)
	if err := os.Mkdir(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(blocked, "occupied")
	if err := os.WriteFile(marker, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	temp, err := os.CreateTemp(dir, ".contract-feed-*.tmp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = temp.Close() })
	archive := zip.NewWriter(temp)
	entry, err := archive.Create("feed_info.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte("feed_publisher_name\ncontract\n")); err != nil {
		t.Fatal(err)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := publishRunFeed(temp, dir); err == nil {
		t.Fatal("run feed publication hid a blocked archive destination")
	}
	body, err := os.ReadFile(marker)
	if err != nil || string(body) != "preserve" {
		t.Fatalf("blocked archive destination changed: %q, %v", body, err)
	}
}

func TestGTFSContractDurablePublicationReportsSyncFailure(t *testing.T) {
	dir := t.TempDir()
	temp, err := os.CreateTemp(dir, ".contract-feed-*.tmp")
	if err != nil {
		t.Fatal(err)
	}
	if err := temp.Close(); err != nil {
		t.Fatal(err)
	}
	final := filepath.Join(dir, "gtfs-final.zip")
	if err := publishGTFSFile(temp, final); err == nil || !strings.Contains(err.Error(), "gtfs export: sync") {
		t.Fatalf("closed-file publication error = %v, want sync failure", err)
	}
	if _, err := os.Stat(final); !os.IsNotExist(err) {
		t.Fatalf("failed durable publication exposed final feed: %v", err)
	}
}

func TestGTFSContractScheduledPublicationLinksAndRetainsNewestFeeds(t *testing.T) {
	core, observed := observer.New(zap.WarnLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	dir := t.TempDir()
	for day := 1; day <= 5; day++ {
		name := fmt.Sprintf("gtfs-202610%02d-1200.zip", day)
		if err := os.WriteFile(filepath.Join(dir, name), []byte("feed"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := finishGTFSBuild(dir, filepath.Join(dir, "gtfs-20261005-1200.zip")); err != nil {
		t.Fatal(err)
	}
	assertLink(t, dir, _gtfsLatestName, "gtfs-20261005-1200.zip")
	for _, day := range []int{3, 4, 5} {
		if _, err := os.Stat(filepath.Join(dir, fmt.Sprintf("gtfs-202610%02d-1200.zip", day))); err != nil {
			t.Fatalf("retained feed day %d: %v", day, err)
		}
	}
	for _, day := range []int{1, 2} {
		if _, err := os.Stat(filepath.Join(dir, fmt.Sprintf("gtfs-202610%02d-1200.zip", day))); !os.IsNotExist(err) {
			t.Fatalf("expired feed day %d remains: %v", day, err)
		}
	}
	if body, err := os.ReadFile(filepath.Join(dir, "notes.txt")); err != nil || string(body) != "keep" {
		t.Fatalf("unrelated file changed: %q, %v", body, err)
	}
	if logs := observed.FilterField(zap.String("action", "prune")).All(); len(logs) != 0 {
		t.Fatalf("successful retention emitted prune failures: %v", logs)
	}
}

func TestGTFSContractScheduledExportLogsDestinationFailureWithoutSuccess(t *testing.T) {
	core, observed := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	blocked := filepath.Join(t.TempDir(), "occupied")
	if err := os.WriteFile(blocked, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(_gtfsOutputDirEnv, blocked)
	RunExport(nil, time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC))
	failures := observed.FilterField(zap.String("event", "failed")).All()
	successes := observed.FilterField(zap.String("event", "success")).All()
	if len(failures) != 1 || len(successes) != 0 || failures[0].ContextMap()["err"] == nil {
		t.Fatalf("scheduled export diagnostics: failures %v, successes %v", failures, successes)
	}
}

func TestGTFSContractArchiveCopyFailureRetainsDatabaseCause(t *testing.T) {
	pool := releaseTestPool(t)
	conn, err := pool.Acquire(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.Release)
	var output bytes.Buffer
	archive := zip.NewWriter(&output)
	t.Cleanup(func() { _ = archive.Close() })
	_, err = writeGTFSZipEntry(t.Context(), conn, archive, gtfsFile{name: "stop_times.txt", sql: "SELECT 1/0 AS invalid_value"})
	requireGTFSContractDatabaseError(t, err, "22012")
}

func TestGTFSContractEnglishRouteTranslationUsesEnglishTermini(t *testing.T) {
	tx := gtfsTestTx(t, gtfsTestPool(t), false)
	if _, err := tx.Exec(t.Context(), `INSERT INTO raw_tdx.bus_route
		(city, routeuid, routeid, routename, operators, departurestopnamezh, destinationstopnamezh, departurestopnameen, destinationstopnameen)
		VALUES ('ZZ_GTFS_LANGUAGE', 'ZZ_GTFS_LANGUAGE_ROUTE', 'language-route', '{"Zh_tw":"中文路線","En":"English route"}', '[{"OperatorID":"OP1"}]', '中文起站', '中文迄站', 'English origin', 'English destination')`); err != nil {
		t.Fatal(err)
	}
	var short, long string
	if err := tx.QueryRow(t.Context(), "SELECT route_short_name, route_long_name FROM ("+gtfsRoutesSQLFor(_gtfsNameEn)+") route WHERE route_id = 'ZZ_GTFS_LANGUAGE_ROUTE'").Scan(&short, &long); err != nil {
		t.Fatal(err)
	}
	if short != "English route" || long != "English origin－English destination" {
		t.Fatalf("English route names = %q / %q, want English route and termini", short, long)
	}
}

func TestGTFSContractScheduledPublicationRejectsBlockedLatestLink(t *testing.T) {
	dir := t.TempDir()
	latest := filepath.Join(dir, _gtfsLatestName)
	if err := os.Mkdir(latest, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(latest, "occupied")
	if err := os.WriteFile(marker, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	final := filepath.Join(dir, "gtfs-20261011-1200.zip")
	if err := os.WriteFile(final, []byte("feed"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := finishGTFSBuild(dir, final); err == nil {
		t.Fatal("scheduled publication hid the blocked latest-link destination")
	}
	if body, err := os.ReadFile(marker); err != nil || string(body) != "preserve" {
		t.Fatalf("blocked latest-link destination changed: %q, %v", body, err)
	}
	if body, err := os.ReadFile(final); err != nil || string(body) != "feed" {
		t.Fatalf("completed archive changed during link failure: %q, %v", body, err)
	}
}

func TestGTFSContractScheduledArchiveReturnsDestinationFailure(t *testing.T) {
	pool := releaseTestPool(t)
	dir := t.TempDir()
	final := filepath.Join(dir, "gtfs-final.zip")
	if err := os.Mkdir(final, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(final, "occupied")
	if err := os.WriteFile(marker, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	temp, err := os.CreateTemp(dir, ".contract-feed-*.tmp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = temp.Close() })
	if _, err := writePublishedGTFSArchive(t.Context(), pool, temp, final, "20261011-1200"); err == nil {
		t.Fatal("scheduled archive hid the blocked final-feed destination")
	}
	if body, err := os.ReadFile(marker); err != nil || string(body) != "preserve" {
		t.Fatalf("blocked final-feed destination changed: %q, %v", body, err)
	}
}
