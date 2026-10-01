package gtfs

import (
	"archive/zip"
	"context"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

const (
	_gtfsExportTimeout = 45 * time.Minute
	// _gtfsOutputDirEnv overrides where feeds are written. The default is a path
	// a volume can be mounted at, since the consumer of these files is another
	// container.
	_gtfsOutputDirEnv     = "GTFS_OUT_DIR"
	_gtfsDefaultOutputDir = "/data/gtfs"
	// _gtfsLatestName is the stable path a planner is pointed at. It is a symlink
	// so that publishing a new feed is one atomic rename rather than a copy.
	_gtfsLatestName = "gtfs.zip"
	// _gtfsKeepFeeds is how many dated builds survive a prune. Enough to roll back
	// to a known-good feed after a bad one ships, not enough to fill the disk.
	_gtfsKeepFeeds = 3
)

// gtfsFile is one entry in the archive. sql must be a complete SELECT; the
// COPY wrapper and CSV framing are added here so no statement can forget them.
type gtfsFile struct {
	name string
	sql  string
}

type gtfsTempTable struct {
	name    string
	sql     string
	indexOn string
}

// gtfsTempTables lists the materialized sets in dependency order: each may read
// the ones before it.
func gtfsTempTables() []gtfsTempTable {
	return []gtfsTempTable{
		{name: _gtfsStopTimeTable, sql: _gtfsStopTimesSQL, indexOn: "trip_id"},
		// stop_areas.txt looks a stop up per fare area, so this one is indexed
		// even though every other reader of it scans.
		{name: _gtfsStopTable, sql: _gtfsStopsSQL, indexOn: "stop_id"},
		// Rail geometry: the clipped segments first, then the trip-to-shape
		// mapping shapes.txt and trips.txt both read. Both are joined to per stop
		// pair and per trip rather than scanned, hence the indexes.
		{name: _gtfsRailSegTable, sql: _gtfsRailSegSQL, indexOn: "from_stop, to_stop"},
		{name: _gtfsRailTripShapeTable, sql: _gtfsRailTripShapeSQL, indexOn: "trip_id"},
		{name: _gtfsFareSrcTable, sql: _busFareSourceSQL, indexOn: "city, routeid"},
		{name: _gtfsStopUIDTable, sql: _busStopUIDSQL, indexOn: "city, stop_id"},
		{name: _gtfsStopSeqTable, sql: _busStopSeqSQL, indexOn: "subrouteuid, direction, stop_id"},
		{name: _gtfsFarePairTable, sql: _busFarePairSQL, indexOn: "routeuid, from_uid, to_uid"},
		{name: _gtfsFareLegTable, sql: _busFareLegSQL},
		{name: _gtfsFarePricedTable, sql: _gtfsFarePricedSQL},
		{name: _gtfsFareZoneTable, sql: _gtfsFareZoneSQL},
	}
}

func gtfsFiles(version string) []gtfsFile {
	return []gtfsFile{
		{"agency.txt", _gtfsAgencySQL},
		// stops.txt is the materialized set itself, not a second evaluation of
		// the query behind it: the fare files filter against these exact ids.
		{"stops.txt", "SELECT * FROM " + _gtfsStopTable},
		{"routes.txt", _gtfsRoutesSQL},
		{"calendar_dates.txt", _gtfsCalendarDatesSQL},
		{"trips.txt", _gtfsTripsSQL},
		{"stop_times.txt", "SELECT * FROM " + _gtfsStopTimeTable},
		{"frequencies.txt", _gtfsFrequenciesSQL},
		{"transfers.txt", _gtfsTransfersSQL},
		{"pathways.txt", _gtfsPathwaysSQL},
		{"shapes.txt", _gtfsShapesSQL},
		{"areas.txt", _gtfsAreasSQL},
		{"stop_areas.txt", _gtfsStopAreasSQL},
		{"fare_products.txt", _gtfsFareProductsSQL},
		{"fare_leg_rules.txt", _gtfsFareLegRulesSQL},
		{"translations.txt", _gtfsTranslationsSQL},
		{"feed_info.txt", gtfsFeedInfoSQL(version)},
		{"attributions.txt", _gtfsAttributionsSQL},
	}
}

func gtfsOutputDir() string {
	if dir := strings.TrimSpace(os.Getenv(_gtfsOutputDirEnv)); dir != "" {
		return dir
	}
	return _gtfsDefaultOutputDir
}

func RunExport(db *pgxpool.Pool, runDate time.Time) {
	ctx, cancel := context.WithTimeout(context.Background(), _gtfsExportTimeout)
	defer cancel()
	started := time.Now()
	path, rows, err := buildGTFSFeed(ctx, db, gtfsOutputDir(), runDate)
	if err != nil {
		zap.S().Errorw("failed", "component", "gtfs", "action", "export", "event", "failed", "err", err)
		return
	}
	zap.S().Infow("success",
		"component", "gtfs",
		"action", "export",
		"event", "success",
		"path", path,
		"rows", rows,
		"elapsed", time.Since(started).Round(time.Millisecond),
	)
}

func buildGTFSFeed(ctx context.Context, db *pgxpool.Pool, dir string, runDate time.Time) (string, int64, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", 0, _oops.With("dir", dir).Wrapf(err, "gtfs export: create")
	}
	version := runDate.Format("20060102-1504")
	final := filepath.Join(dir, "gtfs-"+version+".zip")

	temp, err := os.CreateTemp(dir, ".gtfs-*.zip.tmp")
	if err != nil {
		return "", 0, _oops.Wrapf(err, "gtfs export: create temp")
	}
	tempName := temp.Name()
	// Removing the temp file is a no-op once it has been renamed away.
	defer func() {
		_ = temp.Close()
		_ = os.Remove(tempName)
	}()

	rows, err := writeGTFSArchive(ctx, db, temp, version)
	if err != nil {
		return "", 0, err
	}
	// fsync before the rename: a crash between the two would otherwise publish a
	// name that points at unflushed content.
	if err := temp.Sync(); err != nil {
		return "", 0, _oops.Wrapf(err, "gtfs export: sync")
	}
	if err := temp.Close(); err != nil {
		return "", 0, _oops.Wrapf(err, "gtfs export: close")
	}
	if err := os.Chmod(tempName, 0o644); err != nil {
		return "", 0, _oops.With("temp", tempName).Wrapf(err, "gtfs export: chmod")
	}
	if err := os.Rename(tempName, final); err != nil {
		return "", 0, _oops.With("final", final).Wrapf(err, "gtfs export: publish")
	}
	if err := linkLatestGTFS(dir, filepath.Base(final)); err != nil {
		return "", 0, err
	}
	if err := pruneGTFSFeeds(dir, _gtfsKeepFeeds); err != nil {
		// A failed prune leaves extra files behind; the feed itself is published
		// and usable, so this is reported without failing the build.
		zap.S().Warnw("failed", "component", "gtfs", "action", "prune", "event", "failed", "err", err)
	}
	return final, rows, nil
}

func writeGTFSArchive(ctx context.Context, db *pgxpool.Pool, w io.Writer, version string) (int64, error) {
	conn, err := db.Acquire(ctx)
	if err != nil {
		return 0, _oops.Wrapf(err, "gtfs export: acquire connection")
	}
	defer conn.Release()

	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, _oops.Wrapf(err, "gtfs export: begin")
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"); err != nil {
		return 0, _oops.Wrapf(err, "gtfs export: set snapshot")
	}
	if err := createGTFSTempTables(ctx, tx, true /* withData */); err != nil {
		return 0, err
	}

	zw := zip.NewWriter(w)
	var total int64
	for _, file := range gtfsFiles(version) {
		entry, err := zw.Create(file.name)
		if err != nil {
			return 0, _oops.With("file_name", file.name).Wrapf(err, "gtfs export: create")
		}
		tag, err := conn.Conn().PgConn().CopyTo(ctx, entry,
			"COPY ("+file.sql+") TO STDOUT WITH (FORMAT csv, HEADER true)")
		if err != nil {
			return 0, _oops.With("file_name", file.name).Wrapf(err, "gtfs export: copy")
		}
		zap.S().Infow("written",
			"component", "gtfs",
			"action", "export",
			"file", file.name,
			"rows", tag.RowsAffected(),
			"event", "written",
		)
		total += tag.RowsAffected()
	}
	if err := zw.Close(); err != nil {
		return 0, _oops.Wrapf(err, "gtfs export: finish archive")
	}
	return total, nil
}

func createGTFSTempTables(ctx context.Context, tx pgx.Tx, withData bool) error {
	for _, table := range gtfsTempTables() {
		started := time.Now()
		create := "CREATE TEMP TABLE " + table.name + " ON COMMIT DROP AS " + table.sql
		if !withData {
			if _, err := tx.Exec(ctx, create+" WITH NO DATA"); err != nil {
				return _oops.With("table_name", table.name).Wrapf(err, "gtfs export: declare")
			}
			continue
		}
		if _, err := tx.Exec(ctx, create); err != nil {
			return _oops.With("table_name", table.name).Wrapf(err, "gtfs export: materialize")
		}
		if table.indexOn != "" {
			if _, err := tx.Exec(ctx, "CREATE INDEX ON "+table.name+" ("+table.indexOn+")"); err != nil {
				return _oops.With("table_name", table.name).Wrapf(err, "gtfs export: index")
			}
		}
		// Without this the temp table is as opaque to the planner as the
		// expansion it replaced, and the whole point is lost.
		if _, err := tx.Exec(ctx, "ANALYZE "+table.name); err != nil {
			return _oops.With("table_name", table.name).Wrapf(err, "gtfs export: analyze")
		}
		zap.S().Infow("materialized",
			"component", "gtfs",
			"action", "export",
			"table", table.name,
			"elapsed", time.Since(started).Round(time.Millisecond),
			"event", "materialized",
		)
	}
	return nil
}

// linkLatestGTFS repoints the stable name. The symlink is created under a
// temporary name and renamed over the old one, because os.Symlink cannot replace
// an existing path and unlinking first would leave a window with no feed.
func linkLatestGTFS(dir, target string) error {
	temp := filepath.Join(dir, ".gtfs.zip.link")
	_ = os.Remove(temp)
	if err := os.Symlink(target, temp); err != nil {
		return _oops.Wrapf(err, "gtfs export: link latest")
	}
	if err := os.Rename(temp, filepath.Join(dir, _gtfsLatestName)); err != nil {
		_ = os.Remove(temp)
		return _oops.Wrapf(err, "gtfs export: publish latest")
	}
	return nil
}

// pruneGTFSFeeds keeps the newest keep dated builds and deletes the rest. Names
// are sorted lexically, which is chronological because the timestamp is
// zero-padded and fixed-width.
func pruneGTFSFeeds(dir string, keep int) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return _oops.With("dir", dir).Wrapf(err, "read")
	}
	var feeds []string
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasPrefix(name, "gtfs-") || !strings.HasSuffix(name, ".zip") {
			continue
		}
		feeds = append(feeds, name)
	}
	if len(feeds) <= keep {
		return nil
	}
	sort.Sort(sort.Reverse(sort.StringSlice(feeds)))
	var failures []string
	for _, name := range feeds[keep:] {
		if err := os.Remove(filepath.Join(dir, name)); err != nil {
			failures = append(failures, name)
		}
	}
	if len(failures) > 0 {
		return _oops.With("failures", strings.Join(failures, ", ")).Errorf("remove")
	}
	return nil
}
