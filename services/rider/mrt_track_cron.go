package main

import (
	"context"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/mrttrack"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/notify"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
)

// registerMrtTrackCron schedules the 15s tracker. Empty TRTC credentials make
// GetTrainInfo a no-op, and no session can be created without it, so a
// credential-less environment simply has nothing to advance.
func registerMrtTrackCron(r *cron.Cron, rc *redis.Client, db *pgxpool.Pool, dispatcher *notify.Dispatcher, pusher *notify.TrackPusher) {
	tracker := mrttrack.NewTracker(
		shared.NewTRTCTrainInfoClient(os.Getenv("TRTC_USERNAME"), os.Getenv("TRTC_PASSWORD")),
		rc, notify.NewStore(db), dispatcher, pusher,
	)
	_, _ = addStaticCron(r, "@every 15s", func() {
		pipeline.WithTimeout(mrttrack.TickTimeout, func(ctx context.Context) {
			tracker.Tick(ctx, time.Now().In(pipeline.Taipei))
		})
	})
}
