package main

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

// The bus ETA demand gate only fetches cities someone waits on. Pending
// reminders are rider state, so rider restores their demand keys at boot.
const _reminderDemandCitiesSQL = `
	SELECT left(route_key, 3) AS city_prefix, max(expires_at)
	FROM firebase_arrival_reminder
	WHERE route_type = 'bus' AND status = 'pending' AND expires_at > NOW()
	GROUP BY city_prefix`

func restoreReminderDemand(ctx context.Context, db *pgxpool.Pool, sink pipeline.LiveSink) int {
	if db == nil || sink == nil {
		return 0
	}
	rows, err := db.Query(ctx, _reminderDemandCitiesSQL)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "live",
			"action", "restore_reminder_demand",
			"event", "failed",
			"err", err,
		)
		return 0
	}
	defer rows.Close()

	pipe := sink.Pipe()
	restored := 0
	now := time.Now()
	for rows.Next() {
		var (
			prefix    string
			expiresAt time.Time
		)
		if err := rows.Scan(&prefix, &expiresAt); err != nil {
			zap.S().Errorw("scan failed",
				"component", "live",
				"action", "restore_reminder_demand",
				"event", "failed",
				"err", err,
			)
			return 0
		}
		city := shared.CityFromUID(prefix)
		ttl := expiresAt.Sub(now)
		if city == "" || ttl <= 0 {
			continue
		}
		pipe.Set(shared.LiveDemandKey("bus_eta", city), "1", ttl)
		restored++
	}
	if err := rows.Err(); err != nil {
		zap.S().Errorw("rows failed",
			"component", "live",
			"action", "restore_reminder_demand",
			"event", "failed",
			"err", err,
		)
		return 0
	}
	if restored == 0 {
		return 0
	}
	if err := pipe.Exec(ctx); err != nil {
		zap.S().Errorw("write failed",
			"component", "live",
			"action", "restore_reminder_demand",
			"event", "failed",
			"err", err,
		)
		return 0
	}
	zap.S().Infow("success",
		"component", "live",
		"action", "restore_reminder_demand",
		"event", "success",
		"cities", restored,
	)
	return restored
}
