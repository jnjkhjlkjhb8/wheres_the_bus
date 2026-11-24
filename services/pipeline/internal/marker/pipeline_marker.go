package marker

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"go.uber.org/zap"
)

func recordPipelineMarker(ctx context.Context, db *pgxpool.Pool, job string, runDate time.Time) error {
	_, err := db.Exec(ctx,
		`INSERT INTO pipeline_runs (job, run_date) VALUES ($1, $2)
		 ON CONFLICT (job, run_date) DO UPDATE SET completed_at = now()`,
		job, runDate.Format(time.DateOnly),
	)
	if err != nil {
		return _oops.With("job", job).Wrapf(err, "record pipeline_runs marker")
	}
	return nil
}

func RecordWithRetry(ctx context.Context, db *pgxpool.Pool, job string, runDate time.Time) {
	err := obs.Retry(ctx, 3, 5*time.Second, func() error {
		return obs.Transient(recordPipelineMarker(ctx, db, job, runDate))
	})
	if err != nil {
		zap.S().Errorw("failed",
			"component", "pipeline",
			"action", "record_marker",
			"event", "failed",
			"job", job,
			"run_date", runDate.Format(time.DateOnly),
			"err", err,
		)
		return
	}
	zap.S().Infow("recorded",
		"component", "pipeline",
		"action", "record_marker",
		"event", "recorded",
		"job", job,
		"run_date", runDate.Format(time.DateOnly),
		"gauge", "marker_lag_seconds",
		"value", time.Since(runDate).Seconds(),
	)
}

// SleepCtx waits d or returns ctx.Err() if ctx is done first.
func SleepCtx(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(d):
		return nil
	}
}
