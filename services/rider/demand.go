package main

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
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
	return restoreDatabaseDemand(ctx, db, sink)
}

func restoreDatabaseDemand(ctx context.Context, db *pgxpool.Pool, sink pipeline.LiveSink) int {
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

	return publishRestoredDemand(ctx, rows, sink.Pipe())
}

func publishRestoredDemand(ctx context.Context, rows pgx.Rows, pipe pipeline.LivePipe) int {
	restored, err := queueReminderDemand(rows, pipe)
	if err != nil {
		return 0
	}
	if restored == 0 {
		return 0
	}
	return publishDemandPipeline(ctx, pipe, restored)
}

func publishDemandPipeline(ctx context.Context, pipe pipeline.LivePipe, restored int) int {
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

func queueReminderDemand(rows pgx.Rows, pipe pipeline.LivePipe) (int, error) {
	restored := 0
	now := time.Now()
	for rows.Next() {
		queued, err := queueDemandRow(rows, pipe, now)
		if err != nil {
			return 0, err
		}
		restored += queued
	}
	return completedDemandRows(rows, restored)
}

func completedDemandRows(rows pgx.Rows, restored int) (int, error) {
	if err := rows.Err(); err != nil {
		zap.S().Errorw("rows failed", "component", "live", "action", "restore_reminder_demand", "event", "failed", "err", err)
		return 0, err
	}
	return restored, nil
}

func queueDemandRow(rows pgx.Rows, pipe pipeline.LivePipe, now time.Time) (int, error) {
	var prefix string
	var expiresAt time.Time
	if err := rows.Scan(&prefix, &expiresAt); err != nil {
		zap.S().Errorw("scan failed", "component", "live", "action", "restore_reminder_demand", "event", "failed", "err", err)
		return 0, err
	}
	return queueCityDemand(pipe, prefix, expiresAt.Sub(now)), nil
}

func queueCityDemand(pipe pipeline.LivePipe, prefix string, ttl time.Duration) int {
	city := shared.CityFromUID(prefix)
	if city == "" || ttl <= 0 {
		return 0
	}
	pipe.Set(shared.LiveDemandKey("bus_eta", city), "1", ttl)
	return 1
}
