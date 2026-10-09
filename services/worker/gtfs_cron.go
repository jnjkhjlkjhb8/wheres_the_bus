package main

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/gtfs"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

// registerGTFSRTCron schedules the snapshot rebuild. Like the other live jobs it
// never fails the process: a rebuild that errors leaves the previous snapshot in
// Redis to expire on its own.
func registerGTFSRTCron(r *cron.Cron, db *pgxpool.Pool, rc *redis.Client) {
	builder := gtfs.NewRTBuilder(db, rc)
	_, _ = addStaticCron(r, gtfs.RTCadence, func() {
		ctx, cancel := context.WithTimeout(context.Background(), gtfs.RTBuildTimeout)
		defer cancel()
		if err := builder.Run(ctx, time.Now().In(pipeline.Taipei)); err != nil {
			zap.S().Errorw("failed", "component", "gtfs_rt", "action", "build", "event", "failed", "err", err)
		}
	})
}
