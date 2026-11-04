// Command pipeline runs the static data batches as one-shot processes, one per
// Kubernetes CronJob or manual Job (ADR-0026):
//
//	pipeline run nightly   ingest, load, vector refresh, segment times, GTFS export, prediction-error upkeep, MRT sync
//	pipeline run hourly    bus daily timetable: re-land, then load the cities that changed
//	pipeline run publish   make the run's GTFS export the published one (after MOTIS imported it)
//	pipeline run <step>    one step on its own: ingest, load, vector, gtfs, mrt_sync
//
// PIPELINE_RUN_ID names the run (the Job UID in Kubernetes); nightly's gtfs
// step and the publish container of the same Job share it.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/cleanup"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/gtfs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/marker"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/mrtsync"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	// A nightly run waits this long for a running hourly run to finish before
	// giving up; failing loudly beats skipping the day's full refresh.
	_nightlyLockWait  = 30 * time.Minute
	_nightlyLockRetry = 2 * time.Minute

	_segmentTimeTimeout     = 15 * time.Minute
	_predictionErrorTimeout = 10 * time.Minute
	_mrtSyncTimeout         = 5 * time.Minute
)

func main() {
	os.Exit(runPipelineCLI(os.Args[1:], os.Stderr))
}

func runPipelineCLI(args []string, stderr io.Writer) int {
	if err := run(args); err != nil {
		_, _ = fmt.Fprintf(stderr, "pipeline exited with error: %v\n", err)
		return 1
	}
	return 0
}

type deps struct {
	db, rawPool *pgxpool.Pool
	rc          *redis.Client
	tdx         *shared.TDXClient
}

func run(args []string) error {
	if err := validatePipelineArgs(args); err != nil {
		return err
	}
	defer obs.Init("pipeline")()
	defer obs.Recover("main")

	// This process lands raw_tdx; the ingestor-only switches in raw follow it.
	raw.DumpEnabled = true
	rc := shared.ConnectRedis()
	defer closePipelineResource(rc.Close, "redis")
	db := shared.ConnectDB("PIPELINE_DB_MAX_CONNS", 5)
	defer db.Close()
	raw.DB = db
	return runConfiguredPipeline(db, rc, args[1])
}

func validatePipelineArgs(args []string) error {
	if len(args) != 2 || args[0] != "run" {
		return errors.New("usage: pipeline run <nightly|hourly|publish|ingest|load|vector|gtfs|mrt_sync>")
	}
	return nil
}

func closePipelineResource(closeResource func() error, component string) {
	if err := closeResource(); err != nil {
		zap.S().Errorw("failed", "component", component, "action", "close", "event", "failed", "err", err)
	}
}

func runConfiguredPipeline(db *pgxpool.Pool, rc *redis.Client, name string) error {
	closeArchive, err := history.Init(context.Background(), os.Getenv("ARCHIVE_MYSQL_DSN"))
	if err != nil {
		return err
	}
	defer closePipelineResource(closeArchive, "archive")
	rawPool, closeRawPool, err := rawSourcePool(context.Background(), db)
	if err != nil {
		return err
	}
	defer closeRawPool()
	d := deps{
		db:      db,
		rawPool: rawPool,
		rc:      rc,
		tdx: shared.NewTDXClient(shared.TDXConfig{
			Store:         shared.RedisTDXStore{RC: rc},
			IMSKey:        raw.IMSCacheKey,
			SinceFallback: raw.SinceFallback,
		}),
	}

	return runPipelineStep(context.Background(), d, name)
}

func runPipelineStep(ctx context.Context, d deps, name string) error {
	runners := map[string]func(context.Context, deps) error{
		"nightly":  runNightly,
		"hourly":   runHourly,
		"ingest":   stepIngest,
		"load":     stepLoad,
		"vector":   stepVector,
		"gtfs":     stepGTFS,
		"publish":  runPublish,
		"mrt_sync": stepMRTSync,
	}
	run := runners[name]
	if run == nil {
		return _oops.With("step", name).Errorf("unknown pipeline step")
	}
	return run(ctx, d)
}

type step struct {
	name string
	run  func(context.Context, deps) error
}

// nightlySteps is the nightly order. Segment times precede the GTFS export so
// the feed's stop_times use tonight's values, and the load precedes both.
func nightlySteps() []step {
	return []step{
		{"ingest", stepIngest},
		{"load", stepLoad},
		{"vector", stepVector},
		{"segment_times", stepSegmentTimes},
		{"gtfs", stepGTFS},
		{"prediction_errors", stepPredictionErrors},
		{"mrt_sync", reportMRTSync},
	}
}

// runNightly runs every nightly step in order under the run lock and stops at
// the first failure: a later step must never publish over an earlier one that
// did not finish.
func runNightly(ctx context.Context, d deps) error {
	lock, err := acquireRunLock(ctx, d.rawPool, _nightlyLockWait, _nightlyLockRetry)
	if err != nil {
		return _oops.Wrapf(err, "nightly: acquire run lock")
	}
	defer releasePipelineRunLock(lock)
	return runNightlySteps(ctx, d, nightlySteps())
}

func releasePipelineRunLock(lock *runLock) {
	if err := lock.release(); err != nil {
		zap.S().Errorw("failed", "component", "pipeline", "action", "release_run_lock", "event", "failed", "err", err)
	}
}

func runNightlySteps(ctx context.Context, d deps, steps []step) error {
	for _, s := range steps {
		start := time.Now()
		if err := s.run(ctx, d); err != nil {
			return _oops.With("step", s.name).Wrapf(err, "nightly")
		}
		zap.S().Infow("done", "component", "pipeline", "action", s.name, "event", "done", "took", time.Since(start))
	}
	return nil
}

// runHourly re-lands the bus daily timetable and loads the cities whose landing
// moved. It skips, successfully, when a nightly run holds the lock: the nightly
// run loads every city anyway.
func runHourly(ctx context.Context, d deps) error {
	lock, err := acquireRunLock(ctx, d.rawPool, 0, 0)
	if errors.Is(err, errRunLockBusy) {
		zap.S().Infow("skipped", "component", "pipeline", "action", "hourly", "event", "skipped", "reason", "run_lock_busy")
		return nil
	}
	if err != nil {
		return _oops.Wrapf(err, "hourly: acquire run lock")
	}
	defer releasePipelineRunLock(lock)
	return runHourlyDailyTimetable(ctx, d)
}

func runHourlyDailyTimetable(ctx context.Context, d deps) error {
	if err := ingestHourlyPipelineBatch(ctx, d); err != nil {
		return err
	}
	return loadHourlyDailyTimetable(ctx, d)
}

func ingestHourlyPipelineBatch(ctx context.Context, d deps) error {
	ingest := newStaticPipelineRunner(d.rawPool, _busDailyIngestTimeout)
	if err := ingest.Run(ctx, func(ctx context.Context) error {
		return ingestHourlyDailyTimetable(ctx, d)
	}); err != nil {
		return _oops.Wrapf(err, "hourly: ingest bus_dailytimetable")
	}
	return nil
}

func loadHourlyDailyTimetable(ctx context.Context, d deps) error {
	loaded, err := readLoadedDailyMarkers(ctx, d.rc)
	if err != nil {
		return err
	}
	load := newStaticPipelineRunner(d.rawPool, _busDailyHourlyTimeout)
	loadErr := load.Run(ctx, func(ctx context.Context) error {
		return loadChangedBusDailyTimetables(ctx, d.rawPool, rawTDXSource{pool: d.rawPool}, d.db, d.rc, loaded)
	})
	// Cities that did load are recorded even when others failed, so the next
	// hour only retries the failures.
	return errors.Join(loadErr, writeLoadedDailyMarkers(ctx, d.rc, loaded))
}

func ingestHourlyDailyTimetable(ctx context.Context, d deps) error {
	var taipeiErr error
	if hasTDXCredentials() {
		taipeiErr = bus.LandDataTaipeiDailyTimetable(ctx, bus.NewDataTaipeiFeed(dataset.DataTaipeiCity), time.Now)
	}
	return errors.Join(ingestRaw(ctx, d.tdx, "bus_dailytimetable"), taipeiErr)
}

func stepIngest(ctx context.Context, d deps) error {
	runner := newStaticPipelineRunner(d.rawPool, _ingestTimeout)
	return runner.Run(ctx, func(ctx context.Context) error {
		err := ingestRaw(ctx, d.tdx)
		landTaoyuanTurnarounds(ctx, d.tdx.NewAuthedClient(bus.TaoyuanRouteBaseURL))
		return err
	})
}

// landTaoyuanTurnarounds never fails the ingest: without a fresh landing the
// loader serves Taoyuan's loops unsplit, which is what TDX itself publishes.
func landTaoyuanTurnarounds(ctx context.Context, client *resty.Client) {
	if !hasTDXCredentials() {
		return
	}
	if err := bus.LandTaoyuanTurnarounds(ctx, client); err != nil {
		zap.S().Warnw("failed", "component", "ingest", "action", "taoyuan_route", "event", "failed", "err", err)
	}
}

// stepLoad transforms raw_tdx into the catalog and records the "load" marker
// that /api/static-version reports as the offline-cache epoch.
func stepLoad(ctx context.Context, d deps) error {
	runDate := time.Now().In(pipeline.Taipei)
	runner := newStaticPipelineRunner(d.rawPool, _loadTimeout)
	var stats loadStats
	err := pipeline.RunDailyWithRetry(ctx, _loadTimeout, time.Minute, func(ctx context.Context) error {
		return runner.Run(ctx, func(ctx context.Context) error {
			var runErr error
			stats, runErr = runLoad(ctx, rawTDXSource{pool: d.rawPool}, d.db, d.rc, nil)
			return runErr
		})
	})
	if !markerEarned(stats, err) {
		return errors.Join(err, errors.New("load: no partition loaded"))
	}
	marker.RecordWithRetry(ctx, d.db, "load", runDate)
	return err
}

func stepVector(ctx context.Context, d deps) error {
	runner := newStaticPipelineRunner(d.rawPool, _vectorRefreshTimeout)
	return pipeline.RunDailyWithRetry(ctx, _vectorRefreshTimeout, time.Minute, func(ctx context.Context) error {
		return runner.Run(ctx, vectorRefreshJob(d.rc, d.db))
	})
}

// stepSegmentTimes rebuilds bus_segment_time before the GTFS export, so the
// feed's stop_times use tonight's segment times.
func stepSegmentTimes(ctx context.Context, d deps) error {
	if err := pipeline.RunWithTimeout(ctx, _segmentTimeTimeout, func(ctx context.Context) error {
		return history.ComputeSegmentTimesFromEstimates(ctx, d.db, history.ResolveSource())
	}); err != nil {
		return _oops.Wrapf(err, "compute segment times from estimates")
	}
	return pipeline.RunWithTimeout(ctx, _segmentTimeTimeout, func(ctx context.Context) error {
		return history.FillSegmentTimesFromDistance(ctx, d.db)
	})
}

// reportMRTSync is mrt_sync inside nightly. nightly runs as the Job's init
// container, so a failed step would also skip motis-import and publish; a
// powersync-db outage only leaves the MRT copies a day stale, so it is
// reported instead. `pipeline run mrt_sync` stays strict.
func reportMRTSync(ctx context.Context, d deps) error {
	if err := stepMRTSync(ctx, d); err != nil {
		zap.S().Errorw("failed", "component", "pipeline", "action", "mrt_sync", "event", "failed", "err", err)
	}
	return nil
}

// stepMRTSync copies the tables PowerSync serves to powersync-db (ADR-0028).
// Without MRT_SYNC_DATABASE_URL it skips, which is the state until that
// instance exists.
func stepMRTSync(ctx context.Context, d deps) error {
	dsn := os.Getenv("MRT_SYNC_DATABASE_URL")
	if dsn == "" {
		zap.S().Infow("skipped", "component", "pipeline", "action", "mrt_sync", "event", "skipped", "reason", "no_mrt_sync_database_url")
		return nil
	}
	return pipeline.RunWithTimeout(ctx, _mrtSyncTimeout, func(ctx context.Context) error {
		return mrtsync.Run(ctx, d.db, dsn)
	})
}

// stepGTFS exports this run's feed and GTFS-RT index snapshot. Nothing is
// published yet: realtime and MOTIS keep the active run until runPublish.
func stepGTFS(ctx context.Context, d deps) error {
	m, err := gtfs.ExportRun(ctx, d.rawPool, gtfsRoot(), runID(), time.Now().In(pipeline.Taipei))
	if err != nil {
		return err
	}
	zap.S().Infow("exported", "component", "gtfs", "action", "export", "event", "exported",
		"run_id", m.RunID, "build_seq", m.BuildSeq, "sha256", m.GTFSSHA256)
	return nil
}

// runPublish publishes this run once MOTIS has imported its feed. A run older
// than the published one exits cleanly without touching anything.
func runPublish(ctx context.Context, d deps) error {
	m, err := gtfs.ReadManifest(gtfsRoot(), runID())
	if err != nil {
		return err
	}
	return publishPipelineRun(ctx, d.db, m)
}

func publishPipelineRun(ctx context.Context, db *pgxpool.Pool, m gtfs.Manifest) error {
	if err := gtfs.Publish(ctx, db, gtfsRoot(), m); err != nil {
		return handlePipelinePublishError(err, m)
	}
	zap.S().Infow("published", "component", "gtfs", "action", "publish", "event", "published",
		"run_id", m.RunID, "build_seq", m.BuildSeq)
	prunePublishedPipelineRuns(ctx, db)
	return nil
}

func handlePipelinePublishError(err error, m gtfs.Manifest) error {
	if errors.Is(err, gtfs.ErrStaleRun) {
		zap.S().Warnw("skipped", "component", "gtfs", "action", "publish", "event", "skipped",
			"reason", "stale_run", "run_id", m.RunID, "build_seq", m.BuildSeq)
		return nil
	}
	return err
}

func prunePublishedPipelineRuns(ctx context.Context, db *pgxpool.Pool) {
	// A run directory younger than the nightly deadline may still be exporting.
	if err := gtfs.Prune(ctx, db, gtfsRoot(), _nightlyDeadline); err != nil {
		zap.S().Warnw("failed", "component", "gtfs", "action", "prune", "event", "failed", "err", err)
	}
}

// _nightlyDeadline matches the nightly CronJob's activeDeadlineSeconds.
const _nightlyDeadline = 4 * time.Hour

func gtfsRoot() string {
	if dir := os.Getenv("GTFS_OUT_DIR"); dir != "" {
		return dir
	}
	return "/data/gtfs"
}

// runID is the Job UID in Kubernetes. A run started by hand gets a unique
// one-off name so it can never collide with a scheduled run.
func runID() string {
	if id := os.Getenv("PIPELINE_RUN_ID"); id != "" {
		return id
	}
	return fmt.Sprintf("manual-%d", time.Now().UnixNano())
}

func stepPredictionErrors(ctx context.Context, d deps) error {
	if err := pipeline.RunDailyWithRetry(ctx, _predictionErrorTimeout, time.Minute, func(ctx context.Context) error {
		return history.MeasurePredictionError(ctx, d.db, history.ResolveSource())
	}); err != nil {
		return _oops.Wrapf(err, "measure prediction error")
	}
	return pipeline.RunWithTimeout(ctx, _predictionErrorTimeout, func(ctx context.Context) error {
		return cleanup.PredictionErrors(ctx, d.db)
	})
}
