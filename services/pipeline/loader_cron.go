package main

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
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

// Both entry points share one runner, so the 03:30 tick and a LOAD_ON_BOOT
// run contend for the same advisory lock instead of overlapping.

// Boot deliberately does not retry: a fresh deploy that cannot load
// should surface once and leave the 03:30 tick to redo it, rather than
// hold the advisory lock through three attempts while the service comes up.

// The marker write sits outside attempt on purpose: a failed one-row upsert
// must not re-drive a load that already succeeded, so it gets its own quick
// retry and a distinct log (recordPipelineMarkerWithRetry).

const _vectorRefreshTimeout = 10 * time.Minute

// Marker write is outside the job retry: a failed one-row upsert must not
// re-drive an already successful vector refresh.

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
