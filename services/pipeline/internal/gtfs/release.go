package gtfs

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
)

// Directory layout under the feed root (GTFS_OUT_DIR). Every nightly run writes
// only inside runs/<run_id>/, so two runs can never touch each other's files;
// active and previous are symlinks that publish moves.
const (
	_runsDir      = "runs"
	_activeLink   = "active"
	_previousLink = "previous"
	_runFeed      = "gtfs.zip"
	_runManifest  = "manifest.json"
)

// _publishLockKey serializes publishes. A publish holds it from its version
// check through the static_release row, so an older run can never win a race
// against a newer one that read the same active version.
const _publishLockKey int64 = 0x6275737075626c69

// ErrStaleRun means a newer run is already published; the caller drops its own.
var ErrStaleRun = errors.New("gtfs: a newer run is already published")

// Manifest identifies one run's export. build_seq orders runs; run_id names them.
type Manifest struct {
	RunID      string `json:"run_id"`
	BuildSeq   int64  `json:"build_seq"`
	GTFSSHA256 string `json:"gtfs_sha256"`
}

// RunDir is where run runID keeps its feed and manifest.
func RunDir(root, runID string) string {
	return filepath.Join(root, _runsDir, runID)
}

// ExportRun writes run runID's feed and manifest into its own directory and the
// GTFS-RT index snapshot rows for the same run.
func ExportRun(ctx context.Context, db *pgxpool.Pool, root, runID string, runDate time.Time) (Manifest, error) {
	ctx, cancel := context.WithTimeout(ctx, _gtfsExportTimeout)
	defer cancel()
	var buildSeq int64
	if err := db.QueryRow(ctx, "SELECT nextval('static_build_seq')").Scan(&buildSeq); err != nil {
		return Manifest{}, _oops.Wrapf(err, "gtfs export: next build seq")
	}
	dir := RunDir(root, runID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Manifest{}, _oops.With("dir", dir).Wrapf(err, "gtfs export: create run dir")
	}
	sum, err := writeRunFeed(ctx, db, dir, runDate.Format("20060102-1504"))
	if err != nil {
		return Manifest{}, err
	}
	if err := writeRTSnapshot(ctx, db, runID); err != nil {
		return Manifest{}, err
	}
	m := Manifest{RunID: runID, BuildSeq: buildSeq, GTFSSHA256: sum}
	if err := writeManifest(dir, m); err != nil {
		return Manifest{}, err
	}
	return m, nil
}

func writeRunFeed(ctx context.Context, db *pgxpool.Pool, dir, version string) (string, error) {
	temp, err := os.CreateTemp(dir, ".gtfs-*.zip.tmp")
	if err != nil {
		return "", _oops.Wrapf(err, "gtfs export: create temp")
	}
	tempName := temp.Name()
	defer func() {
		_ = temp.Close()
		_ = os.Remove(tempName)
	}()
	hash := sha256.New()
	if _, err := writeGTFSArchive(ctx, db, io.MultiWriter(temp, hash), version); err != nil {
		return "", err
	}
	// fsync before the rename, as in buildGTFSFeed.
	if err := temp.Sync(); err != nil {
		return "", _oops.Wrapf(err, "gtfs export: sync")
	}
	if err := temp.Close(); err != nil {
		return "", _oops.Wrapf(err, "gtfs export: close")
	}
	if err := os.Chmod(tempName, 0o644); err != nil {
		return "", _oops.Wrapf(err, "gtfs export: chmod")
	}
	if err := os.Rename(tempName, filepath.Join(dir, _runFeed)); err != nil {
		return "", _oops.Wrapf(err, "gtfs export: publish run feed")
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func writeManifest(dir string, m Manifest) error {
	body, err := json.Marshal(m)
	if err != nil {
		return _oops.Wrapf(err, "gtfs export: encode manifest")
	}
	tmp := filepath.Join(dir, "."+_runManifest+".tmp")
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return _oops.Wrapf(err, "gtfs export: write manifest")
	}
	return os.Rename(tmp, filepath.Join(dir, _runManifest))
}

// ReadManifest loads run runID's manifest; a run without one never finished
// its export and cannot be published.
func ReadManifest(root, runID string) (Manifest, error) {
	body, err := os.ReadFile(filepath.Join(RunDir(root, runID), _runManifest))
	if err != nil {
		return Manifest{}, _oops.With("run_id", runID).Wrapf(err, "gtfs publish: read manifest")
	}
	var m Manifest
	if err := json.Unmarshal(body, &m); err != nil {
		return Manifest{}, _oops.With("run_id", runID).Wrapf(err, "gtfs publish: decode manifest")
	}
	if m.RunID != runID {
		return Manifest{}, _oops.With("run_id", runID, "manifest_run_id", m.RunID).Errorf("gtfs publish: manifest names another run")
	}
	return m, nil
}

// The snapshot rows are exactly what the GTFS-RT index used to read from
// raw_tdx and the catalog at load time, frozen per run.
var (
	_snapshotBusTripSQL = `
INSERT INTO gtfs_rt_bus_trip (run_id, trip_id, direction_id, service_id)
SELECT DISTINCT $1::text, trip_id, direction_id, service_id
FROM (
  SELECT trip_id, direction_id, service_id FROM (` + _busScheduleSource + `) s
  UNION ALL
  SELECT trip_id, direction_id, service_id FROM (` + _busPatternTripsSQL + `) o
) t
WHERE trip_id <> '' AND service_id LIKE 'W:%'`

	// One row per TRA train per service date in the calendar window, so the
	// index can switch to the next day's trip_ids even when no later run lands.
	_snapshotRailTripSQL = `
INSERT INTO gtfs_rt_rail_trip (run_id, service_date, train_no, trip_id, stations)
SELECT $1::text, t.service_date, t.train_no,
       t.operator || ':' || t.train_no || ':' || to_char(t.service_date, 'YYYYMMDD'),
       array_agg(DISTINCT c->>'StationID')
FROM (` + _railTripSource + `) t
CROSS JOIN LATERAL jsonb_array_elements(t.stoptimes) c
WHERE t.operator = 'TRA'
  AND jsonb_typeof(t.stoptimes) = 'array'
  AND COALESCE(c->>'StationID', '') <> ''
GROUP BY t.service_date, t.train_no, t.operator
HAVING count(*) > 1`

	_snapshotBusOffsetSQL = `
INSERT INTO gtfs_rt_bus_offset (run_id, sub_route_uid, direction, stop_uid, offset_secs)
SELECT $1::text, p.sub_route_uid, p.direction, p.stop_uid, p.offset_secs
FROM (` + busmodel.PatternSQL + `) p
WHERE p.complete`
)

func writeRTSnapshot(ctx context.Context, db *pgxpool.Pool, runID string) error {
	return pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		for _, table := range []string{"gtfs_rt_bus_trip", "gtfs_rt_rail_trip", "gtfs_rt_bus_offset"} {
			// A retried run reuses its run_id; start its snapshot over.
			if _, err := tx.Exec(ctx, "DELETE FROM "+table+" WHERE run_id = $1", runID); err != nil {
				return _oops.With("table", table).Wrapf(err, "gtfs-rt snapshot: clear")
			}
		}
		for _, stmt := range []string{_snapshotBusTripSQL, _snapshotRailTripSQL, _snapshotBusOffsetSQL} {
			if _, err := tx.Exec(ctx, stmt, runID); err != nil {
				return _oops.Wrapf(err, "gtfs-rt snapshot: write")
			}
		}
		return nil
	})
}

// Publish makes run m the published static data: active points at it, the
// previous active becomes previous, and static_release records it. A run older
// than the published one is refused with ErrStaleRun.
func Publish(ctx context.Context, db *pgxpool.Pool, root string, m Manifest) error {
	conn, err := db.Acquire(ctx)
	if err != nil {
		return _oops.Wrapf(err, "gtfs publish: acquire connection")
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", _publishLockKey); err != nil {
		return _oops.Wrapf(err, "gtfs publish: lock")
	}
	defer func() {
		_, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", _publishLockKey)
	}()
	var latest int64
	if err := conn.QueryRow(ctx, "SELECT COALESCE(max(build_seq), 0) FROM static_release").Scan(&latest); err != nil {
		return _oops.Wrapf(err, "gtfs publish: read published build seq")
	}
	if m.BuildSeq <= latest {
		return ErrStaleRun
	}
	if err := switchActive(root, m.RunID); err != nil {
		return err
	}
	if _, err := conn.Exec(ctx,
		"INSERT INTO static_release (run_id, build_seq, gtfs_sha256) VALUES ($1, $2, $3)",
		m.RunID, m.BuildSeq, m.GTFSSHA256); err != nil {
		return _oops.Wrapf(err, "gtfs publish: record release")
	}
	return nil
}

// switchActive repoints active at runID and previous at the old active. Each
// link is replaced by a rename, which is atomic, so a reader always sees one
// whole run.
func switchActive(root, runID string) error {
	target := filepath.Join(_runsDir, runID)
	if old, err := os.Readlink(filepath.Join(root, _activeLink)); err == nil && old != target {
		if err := replaceLink(root, _previousLink, old); err != nil {
			return err
		}
	}
	return replaceLink(root, _activeLink, target)
}

func replaceLink(root, name, target string) error {
	tmp := filepath.Join(root, "."+name+".tmp")
	_ = os.Remove(tmp)
	if err := os.Symlink(target, tmp); err != nil {
		return _oops.With("link", name).Wrapf(err, "gtfs publish: link")
	}
	if err := os.Rename(tmp, filepath.Join(root, name)); err != nil {
		return _oops.With("link", name).Wrapf(err, "gtfs publish: swap link")
	}
	return nil
}

// Prune deletes runs older than the previous run, files and snapshot rows
// alike, keeping active, previous and anything that may still be exporting:
// a run directory younger than minAge is never touched.
func Prune(ctx context.Context, db *pgxpool.Pool, root string, minAge time.Duration) error {
	var previousSeq int64
	err := db.QueryRow(ctx, `
		SELECT COALESCE((SELECT build_seq FROM static_release ORDER BY build_seq DESC OFFSET 1 LIMIT 1), 0)`).Scan(&previousSeq)
	if err != nil {
		return _oops.Wrapf(err, "gtfs prune: read previous build seq")
	}
	if previousSeq == 0 {
		return nil
	}
	entries, err := os.ReadDir(filepath.Join(root, _runsDir))
	if err != nil {
		return _oops.Wrapf(err, "gtfs prune: list runs")
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	var errs []error
	for _, e := range entries {
		m, err := ReadManifest(root, e.Name())
		if err != nil || m.BuildSeq >= previousSeq {
			continue
		}
		info, err := e.Info()
		if err != nil || time.Since(info.ModTime()) < minAge {
			continue
		}
		if err := os.RemoveAll(RunDir(root, e.Name())); err != nil {
			errs = append(errs, err)
			continue
		}
	}
	for _, table := range []string{"gtfs_rt_bus_trip", "gtfs_rt_rail_trip", "gtfs_rt_bus_offset"} {
		if _, err := db.Exec(ctx, "DELETE FROM "+table+` WHERE run_id NOT IN (
			SELECT run_id FROM static_release WHERE build_seq >= $1)
			AND run_id IN (SELECT run_id FROM static_release)`, previousSeq); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
