package main

import (
	"context"
	"fmt"
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

func main() {
	if err := run(); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "functions exited with error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	defer obs.Init("functions")()
	defer obs.Recover("main")

	zap.S().Infow("log", "component", "boot", "action", "start")

	r := cron.New(cron.WithSeconds())
	rc := shared.ConnectRedis()
	db := shared.ConnectDB("FUNCTIONS_DB_MAX_CONNS", 10)
	_health = newHealthFile(defaultHealthFilePath())
	defer func(rc *redis.Client) {
		if cerr := rc.Close(); cerr != nil {
			zap.S().Errorw("failed", "component", "redis", "action", "close", "event", "failed", "err", cerr)
		}
	}(rc)
	defer db.Close()
	closeArchive, err := history.Init(context.Background(), os.Getenv("ARCHIVE_MYSQL_DSN"))
	if err != nil {
		return err
	}
	defer func() {
		if cerr := closeArchive(); cerr != nil {
			zap.S().Errorw("failed", "component", "archive", "action", "close", "event", "failed", "err", cerr)
		}
	}()
	// Live fetches never fall back to a table's updated_at: that fallback only
	// ever matched the static datasets, which the pipeline service lands.
	tdx := shared.NewTDXClient(shared.TDXConfig{
		Store:  shared.RedisTDXStore{RC: rc},
		IMSKey: shared.TDXLegacyIMSKey,
		Tap:    history.LiveArchiveTap,
	})
	// One-shot manual trigger: `functions run <job>` runs a live job once and
	// exits, bypassing cron. Needs the same env as the scheduled run.
	if len(os.Args) > 2 && os.Args[1] == "run" {
		return runOnce(os.Args[2], tdx, rc, db)
	}
	return runRealtime(r, tdx, rc, db)
}

// _manualRunTimeout bounds a `functions run <job>` one-shot.
const _manualRunTimeout = 2 * time.Hour

func runOnce(job string, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool) error {
	switch job {
	case "gtfs-rt":
		ctx, cancel := context.WithTimeout(context.Background(), gtfs.RTIndexTimeout)
		defer cancel()
		builder := gtfs.NewRTBuilder(db, rc)
		if err := builder.Run(ctx, time.Now().In(pipeline.Taipei)); err != nil {
			return _oops.Wrapf(err, "gtfs-rt failed")
		}
	case "bikeeta", "traeta", "buseta":
		ctx, cancel := context.WithTimeout(context.Background(), _manualRunTimeout)
		defer cancel()
		name := map[string]string{"bikeeta": "bike", "traeta": "tra", "buseta": "bus"}[job]
		var pool *pgxpool.Pool
		if name == "bus" {
			pool = db
		}
		pipeline.RunLive(ctx, pipeline.NewRESTLiveSource(tdx), pipeline.NewRedisLiveSink(rc), liveRegistry(pool, nil), []string{name})
	default:
		return _oops.With("args", job).Errorf("unknown job")
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

func runRealtime(r *cron.Cron, tdx *shared.TDXClient, rc *redis.Client, db *pgxpool.Pool) error {
	holidayCtx, holidayCancel := context.WithTimeout(context.Background(), holiday.HTTPTimeout)
	if err := holiday.Load(holidayCtx); err != nil {
		zap.S().Warnw("initial refresh failed; weekend/last-good fallback active",
			"component", "holiday",
			"err", err,
		)
	}
	holidayCancel()
	predict.Install()
	weatherCtx, weatherCancel := context.WithTimeout(context.Background(), weather.HTTPTimeout)
	if err := weather.Sync(weatherCtx, rc); err != nil {
		zap.S().Warnw("initial sync failed; keeping last good Redis snapshot",
			"component", "weather",
			"err", err,
		)
	}
	weatherCancel()
	// Arrival events go to rider, which owns reminders and push delivery.
	registerLiveCrons(r, tdx, rc, db, riderevent.Publisher{RC: rc})
	registerGTFSRTCron(r, db, rc)
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
		pipeline.RunDaily("maintainArchivePartitions", 10*time.Minute, func(ctx context.Context) error {
			return history.MaintainPartitions(ctx, history.AdminTarget(), time.Now())
		})
		history.ReportGaps()
	})
	r.Start()
	_health.touch()
	mqttClient := mqtt.StartMQTT(rc, db, history.ArchiveMQTTMessage)
	waitForShutdown()
	// Stop intake first: MQTT (no more messages dispatched) then cron (no
	// more ticks fired). Only then wait for whatever is already in flight.
	if mqttClient != nil {
		mqttClient.Disconnect(500)
	}
	drainShutdown(r.Stop(), &sync.WaitGroup{}, _shutdownGrace)
	return nil
}

func waitForShutdown() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	zap.S().Infow("signal received", "component", "boot", "action", "shutdown", "event", "signal_received")
}

const _shutdownGrace = 30 * time.Second

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
