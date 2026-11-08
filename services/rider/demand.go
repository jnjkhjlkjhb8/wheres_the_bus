package main

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/firebase"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"go.uber.org/zap"
)

// The bus ETA demand gate only fetches cities someone waits on. Pending
// reminders are rider state, so rider restores their demand keys at boot.
const _reminderDemandCitiesSQL = `
	SELECT left(route_key, 3) AS city_prefix, max(expires_at)
	FROM firebase_arrival_reminder
	WHERE route_type = 'bus' AND status = 'pending' AND expires_at > NOW()
	GROUP BY city_prefix`

// restoreReminderDemand re-claims each pending reminder's city through live,
// which never shortens a longer claim already in Redis.
func restoreReminderDemand(ctx context.Context, db *pgxpool.Pool, live firebase.DemandToucher) int {
	if db == nil || live == nil {
		return 0
	}
	return restoreDatabaseDemand(ctx, db, live)
}

func restoreDatabaseDemand(ctx context.Context, db *pgxpool.Pool, live firebase.DemandToucher) int {
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

	return reportRestoredDemand(touchReminderDemand(ctx, rows, live))
}

func reportRestoredDemand(restored int, err error) int {
	if err != nil {
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

func touchReminderDemand(ctx context.Context, rows pgx.Rows, live firebase.DemandToucher) (int, error) {
	restored := 0
	now := time.Now()
	for rows.Next() {
		touched, err := touchDemandRow(ctx, rows, live, now)
		if err != nil {
			return 0, err
		}
		restored += touched
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

func touchDemandRow(ctx context.Context, rows pgx.Rows, live firebase.DemandToucher, now time.Time) (int, error) {
	var prefix string
	var expiresAt time.Time
	if err := rows.Scan(&prefix, &expiresAt); err != nil {
		zap.S().Errorw("scan failed", "component", "live", "action", "restore_reminder_demand", "event", "failed", "err", err)
		return 0, err
	}
	return touchCityDemand(ctx, live, prefix, expiresAt.Sub(now)), nil
}

func touchCityDemand(ctx context.Context, live firebase.DemandToucher, prefix string, ttl time.Duration) int {
	city := shared.CityFromUID(prefix)
	if city == "" || ttl <= 0 {
		return 0
	}
	live.Touch(ctx, shared.LiveDemandKey("bus_eta", city), ttl)
	return 1
}
