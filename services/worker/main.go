package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/holiday"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/weather"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/gtfs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/mqtt"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

func main() { os.Exit(commandExitCode(run(), os.Stderr)) }

func commandExitCode(err error, output io.Writer) int {
	if err == nil {
		return 0
	}
	_, _ = fmt.Fprintf(output, "functions exited with error: %v\n", err)
	return 1
}

func run() error { return runWorker(os.Args, waitForShutdown) }

func runWorker(args []string, waitShutdown func()) error {
	defer obs.Init("functions")()
	defer obs.Recover("main")

	zap.S().Infow("log", "component", "boot", "action", "start")

	r := cron.New(cron.WithSeconds())
	rc := shared.ConnectRedis()
	db := shared.ConnectDB("FUNCTIONS_DB_MAX_CONNS", 10)
	_health = newHealthFile(defaultHealthFilePath())
	defer closeWorkerRedis(rc)
	defer db.Close()
	closeArchive, err := history.Init(context.Background(), os.Getenv("ARCHIVE_MYSQL_DSN"))
	if err != nil {
		return err
	}
	defer closeWorkerArchive(closeArchive)
	// Live fetches never fall back to a table's updated_at: that fallback only
	// ever matched the static datasets, which the pipeline service lands.
	tdx := shared.NewTDXClient(shared.TDXConfig{
		Store:  shared.RedisTDXStore{RC: rc},
		IMSKey: shared.TDXLegacyIMSKey,
		Tap:    history.LiveArchiveTap,
	})
	// One-shot manual trigger: `functions run <job>` runs a live job once and
	// exits, bypassing cron. Needs the same env as the scheduled run.
	if isManualWorkerRun(args) {
		return runOnce(args[2], tdx, rc, db)
	}
	return runRealtimeWithShutdown(r, tdx, rc, db, waitShutdown)
}

func isManualWorkerRun(args []string) bool { return len(args) > 2 && args[1] == "run" }

func closeWorkerRedis(rc *redis.Client) {
	if err := rc.Close(); err != nil {
		zap.S().Errorw("failed", "component", "redis", "action", "close", "event", "failed", "err", err)
	}
}

func closeWorkerArchive(closeArchive func() error) {
	if err := closeArchive(); err != nil {
		zap.S().Errorw("failed", "component", "archive", "action", "close", "event", "failed", "err", err)
	}
}

// _manualRunTimeout bounds a `functions run <job>` one-shot.
const _manualRunTimeout = 2 * time.Hour

func runOnce(job string, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool) error {
	if job == "gtfs-rt" {
		return runManualGTFS(db, rc)
	}
	name, err := manualLiveJob(job)
	if err != nil {
		return err
	}
	runManualLive(name, tdx, rc, db)
	return nil
}

func runManualGTFS(db *pgxpool.Pool, rc *redis.Client) error {
	ctx, cancel := context.WithTimeout(context.Background(), gtfs.RTIndexTimeout)
	defer cancel()
	if err := gtfs.NewRTBuilder(db, rc).Run(ctx, time.Now().In(pipeline.Taipei)); err != nil {
		return _oops.Wrapf(err, "gtfs-rt failed")
	}
	return nil
}

func runManualLive(name string, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool) {
	ctx, cancel := context.WithTimeout(context.Background(), _manualRunTimeout)
	defer cancel()
	pipeline.RunLive(ctx, pipeline.NewRESTLiveSource(tdx), pipeline.NewRedisLiveSink(rc), liveRegistry(manualLivePool(name, db), nil, nil), []string{name})
}

// manualLivePool hands the database only to the bus job; every other manual
// run must stay free of it so a one-shot cannot touch the archive tables.
func manualLivePool(name string, db *pgxpool.Pool) *pgxpool.Pool {
	if name == "bus" {
		return db
	}
	return nil
}

func addStaticCron(r *cron.Cron, spec string, job func()) (cron.EntryID, error) {
	guarded := cron.NewChain(cron.SkipIfStillRunning(cron.DefaultLogger)).Then(cron.FuncJob(func() {
		job()
		_health.touch()
	}))
	return r.AddJob(spec, guarded)
}

func runRealtimeWithShutdown(r *cron.Cron, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool, waitShutdown func()) error {
	refreshBootHoliday()
	predict.Install()
	refreshBootWeather(rc)
	waker := registerWorkerCrons(r, tdx, rc, db)
	r.Start()
	_health.touch()
	stopWakes := waker.listen(rc)
	mqttClient := mqtt.StartMQTT(rc, db, history.ArchiveMQTTMessage)
	waitShutdown()
	// Stop intake before draining jobs so shutdown cannot dispatch more work.
	if mqttClient != nil {
		mqttClient.Disconnect(500)
	}
	stopWakes()
	drainShutdown(r.Stop(), &waker.runs, _shutdownGrace)
	return nil
}

func refreshBootHoliday() {
	holidayCtx, holidayCancel := context.WithTimeout(context.Background(), holiday.HTTPTimeout)
	if err := holiday.Load(holidayCtx); err != nil {
		zap.S().Warnw("initial refresh failed; weekend/last-good fallback active",
			"component", "holiday",
			"err", err,
		)
	}
	holidayCancel()
}

func refreshBootWeather(rc *redis.Client) {
	weatherCtx, weatherCancel := context.WithTimeout(context.Background(), weather.HTTPTimeout)
	if err := weather.Sync(weatherCtx, rc); err != nil {
		zap.S().Warnw("initial sync failed; keeping last good Redis snapshot",
			"component", "weather",
			"err", err,
		)
	}
	weatherCancel()
}

func registerWorkerCrons(r *cron.Cron, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool) *liveWaker {
	// Arrival events go to rider, which owns reminders and push delivery.
	waker := registerLiveCrons(r, tdx, rc, db, riderevent.Publisher{RC: rc})
	registerGTFSRTCron(r, db, rc)
	registerTDXUsageCrons(r, rc)
	_, _ = addStaticCron(r, "@every 10m", func() {
		ctx, cancel := context.WithTimeout(context.Background(), weather.HTTPTimeout)
		defer cancel()
		if err := weather.Sync(ctx, rc); err != nil {
			zap.S().Warnw("sync failed; keeping last good Redis snapshot",
				"component", "weather",
				"err", err,
			)
		}
	})
	_, _ = addStaticCron(r, "@every 24h", func() {
		ctx, cancel := context.WithTimeout(context.Background(), holiday.HTTPTimeout)
		defer cancel()
		if err := holiday.Load(ctx); err != nil {
			zap.S().Warnw("refresh failed; keeping last good snapshot", "component", "holiday", "err", err)
		}
	})
	// Daily upkeep of the archive this service writes.
	_, _ = addStaticCron(r, "0 30 4 * * *", func() {
		pipeline.RunDaily("maintainArchivePartitions", _archiveMaintenanceTimeout, func(ctx context.Context) error {
			return history.MaintainPartitions(ctx, history.AdminTarget(), time.Now())
		})
		history.ReportGaps()
	})
	return waker
}

func waitForShutdown() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	zap.S().Infow("signal received", "component", "boot", "action", "shutdown", "event", "signal_received")
}

const _shutdownGrace = 30 * time.Second

const _archiveMaintenanceTimeout = 10 * time.Minute

func drainShutdown(cronDone context.Context, boot *sync.WaitGroup, grace time.Duration) {
	done := make(chan struct{})
	go func() {
		<-cronDone.Done()
		if boot != nil {
			boot.Wait()
		}
		close(done)
	}()
	select {
	case <-done:
		zap.S().Infow("jobs drained", "component", "boot", "action", "shutdown", "event", "jobs_drained")
	case <-time.After(grace):
		zap.S().Warnw("grace timeout",
			"component", "boot",
			"action", "shutdown",
			"event", "grace_timeout",
			"grace", grace,
		)
	}
}
