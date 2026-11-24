package main

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

// _arrivalWatchSQL lists every reminder queryArrivalMatches could still match.
// It may list more (a device with push turned off), never fewer, or realtime
// would hold back an arrival a reminder is waiting on.
const _arrivalWatchSQL = `
	SELECT DISTINCT route_type, route_key, stop_key, direction
	FROM firebase_arrival_reminder
	WHERE status IN ('pending', 'sending') AND expires_at > NOW()`

// A new reminder starts receiving arrivals within one refresh period.
const (
	_arrivalWatchPeriod  = "@every 10s"
	_arrivalWatchTimeout = 5 * time.Second
)

func registerArrivalWatchCron(r *cron.Cron, db *pgxpool.Pool, rc redis.Cmdable) {
	_, _ = addStaticCron(r, _arrivalWatchPeriod, func() { runArrivalWatchRefresh(db, rc) })
}

func runArrivalWatchRefresh(db *pgxpool.Pool, rc redis.Cmdable) {
	pipeline.WithTimeout(_arrivalWatchTimeout, func(ctx context.Context) {
		if err := refreshArrivalWatch(ctx, db, rc); err != nil {
			zap.S().Errorw("failed", "component", "arrivals", "action", "refresh_watch", "event", "failed", "err", err)
		}
	})
}

// refreshArrivalWatch tells realtime which arrivals a reminder is waiting on.
func refreshArrivalWatch(ctx context.Context, db *pgxpool.Pool, rc redis.Cmdable) error {
	rows, err := db.Query(ctx, _arrivalWatchSQL)
	if err != nil {
		return _oops.Wrapf(err, "query arrival watch")
	}
	members, err := pgx.CollectRows(rows, scanWatchMember)
	if err != nil {
		return _oops.Wrapf(err, "read arrival watch")
	}
	return riderevent.StoreWatch(ctx, rc, members)
}

func scanWatchMember(row pgx.CollectableRow) (string, error) {
	var routeType, routeKey, stopKey, direction string
	err := row.Scan(&routeType, &routeKey, &stopKey, &direction)
	return riderevent.WatchMember(routeType, routeKey, stopKey, direction), err
}
