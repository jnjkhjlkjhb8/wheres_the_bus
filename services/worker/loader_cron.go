package main

import (
	"context"
	"errors"
	"os"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/gtfs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/marker"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

func rawSourcePool(ctx context.Context, db *pgxpool.Pool) (*pgxpool.Pool, func(), error) {
	if ctx == nil {
		ctx = context.Background()
	}
	dsn := os.Getenv("RAW_DATABASE_URL")
	if dsn == "" {
		return db, func() {}, nil
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, nil, _oops.Wrapf(err, "parse configured RAW_DATABASE_URL")
	}
	cfg.MaxConns = shared.EnvInt32("RAW_DB_MAX_CONNS", 4)
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, nil, _oops.Wrapf(err, "connect configured RAW_DATABASE_URL")
	}
	pingCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, nil, _oops.Wrapf(err, "ping configured RAW_DATABASE_URL")
	}
	zap.S().Infow("connected",
		"component", "load",
		"action", "raw_pool",
		"event", "connected",
		"source", "RAW_DATABASE_URL",
	)
	return pool, pool.Close, nil
}

const _loadTimeout = 60 * time.Minute

func registerLoaderCrons(r *cron.Cron, rawPool, db *pgxpool.Pool, rc *redis.Client, boot *sync.WaitGroup) {
	src := rawTDXSource{pool: rawPool}
	runner := newStaticPipelineRunner(rawPool, _loadTimeout)
	// Both entry points share one runner, so the 03:30 tick and a LOAD_ON_BOOT
	// run contend for the same advisory lock instead of overlapping.
	_, _ = addStaticCron(r, "0 30 3 * * *", func() {
		runLoadStage("crontab", "load", src, rawPool, db, rc, func(job func(context.Context) error) error {
			return pipeline.RunDailyWithRetry(context.Background(), _loadTimeout, time.Minute, func(ctx context.Context) error {
				return runner.Run(ctx, job)
			})
		})
	})
	if os.Getenv("LOAD_ON_BOOT") == "true" {
		zap.S().Infow("enabled", "component", "load", "action", "boot", "event", "enabled")
		trackBoot(boot, func() {
			// Boot deliberately does not retry: a fresh deploy that cannot load
			// should surface once and leave the 03:30 tick to redo it, rather than
			// hold the advisory lock through three attempts while the service comes up.
			runLoadStage("load", "boot", src, rawPool, db, rc, func(job func(context.Context) error) error {
				return runner.Run(context.Background(), job)
			})
		})
	} else {
		zap.S().Warnw("skipped", "component", "load", "action", "boot", "event", "skipped")
	}
	registerBusDailyTimetableCron(r, rawPool, db, rc)
}

func runLoadStage(
	component, action string,
	src rawTDXSource,
	rawPool, db *pgxpool.Pool,
	rc *redis.Client,
	attempt func(job func(context.Context) error) error,
) {
	runDate := time.Now().In(pipeline.Taipei)
	var stats loadStats
	err := attempt(func(ctx context.Context) error {
		var runErr error
		stats, runErr = runLoad(ctx, src, db, rc, nil)
		return runErr
	})
	if err != nil {
		zap.S().Errorw("failed",
			"component", component,
			"action", action,
			"event", "failed",
			"ok", stats.ok,
			"failed", stats.failed,
			"skipped", stats.skipped,
			"err", err,
		)
	}
	if !markerEarned(stats, err) {
		return
	}
	// The marker write sits outside attempt on purpose: a failed one-row upsert
	// must not re-drive a load that already succeeded, so it gets its own quick
	// retry and a distinct log (recordPipelineMarkerWithRetry).
	marker.RecordWithRetry(context.Background(), db, "load", runDate)
	runVectorRefresh(rawPool, db, rc, runDate)
	gtfs.RunExport(rawPool, runDate)
}

const _vectorRefreshTimeout = 10 * time.Minute

func runVectorRefresh(rawPool, db *pgxpool.Pool, rc *redis.Client, runDate time.Time) {
	job := vectorRefreshJob(rc, db)
	runner := newStaticPipelineRunner(rawPool, _vectorRefreshTimeout)
	err := pipeline.RunDailyWithRetry(context.Background(), _vectorRefreshTimeout, time.Minute, func(ctx context.Context) error {
		return runner.Run(ctx, job)
	})
	if err != nil {
		zap.S().Errorw("failed", "component", "crontab", "action", "changetovector", "event", "failed", "err", err)
		return
	}
	// Marker write is outside the job retry: a failed one-row upsert must not
	// re-drive an already successful vector refresh.
	marker.RecordWithRetry(context.Background(), db, "changetovector", runDate)
}

func markerEarned(stats loadStats, err error) bool {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		zap.S().Errorw("withheld",
			"component", "load",
			"action", "marker",
			"event", "withheld",
			"reason", "run_truncated",
			"ok", stats.ok,
		)
		return false
	}
	if stats.ok == 0 {
		zap.S().Errorw("withheld",
			"component", "load",
			"action", "marker",
			"event", "withheld",
			"reason", "no_partition_loaded",
			"failed", stats.failed,
			"skipped", stats.skipped,
		)
		return false
	}
	return true
}
