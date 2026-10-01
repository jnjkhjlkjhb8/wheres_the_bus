package marker

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"go.uber.org/zap"
)

// Reader checks pipeline_runs for a completed job on a given
// date. The narrow interface keeps Wait testable without a
// live database.
type Reader interface {
	MarkerExists(ctx context.Context, job string, runDate time.Time) (bool, error)
}

// PGReader queries pipeline_runs against db (this environment's
// PG_SCHEMA). pipeline_runs is unqualified, like every other transform target
// table, so it resolves through db's search_path.
type PGReader struct{ db *pgxpool.Pool }

func (r PGReader) MarkerExists(ctx context.Context, job string, runDate time.Time) (bool, error) {
	var exists bool
	err := r.db.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM pipeline_runs WHERE job = $1 AND run_date = $2)`,
		job, runDate.Format(time.DateOnly),
	).Scan(&exists)
	if err != nil {
		return false, _oops.With("job", job).Wrapf(err, "query pipeline_runs marker")
	}
	return exists, nil
}

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

const (
	PollInterval = 5 * time.Minute
	PollDeadline = 2 * time.Hour
)

func Wait(
	ctx context.Context,
	reader Reader,
	job string,
	runDate time.Time,
	interval, deadline time.Duration,
	now func() time.Time,
	sleep func(context.Context, time.Duration) error,
) error {
	deadlineAt := now().Add(deadline)
	var lastErr error
	for {
		ok, err := reader.MarkerExists(ctx, job, runDate)
		if err != nil {
			lastErr = err
			zap.S().Errorw("read error",
				"component", "pipeline",
				"action", "wait_marker",
				"event", "read_error",
				"job", job,
				"run_date", runDate.Format(time.DateOnly),
				"err", err,
			)
		} else {
			lastErr = nil
			if ok {
				return nil
			}
			zap.S().Warnw("not ready",
				"component", "pipeline",
				"action", "wait_marker",
				"event", "not_ready",
				"job", job,
				"run_date", runDate.Format(time.DateOnly),
			)
		}
		if !now().Before(deadlineAt) {
			zap.S().Errorw("give up",
				"component", "pipeline",
				"action", "wait_marker",
				"event", "give_up",
				"job", job,
				"run_date", runDate.Format(time.DateOnly),
			)
			if lastErr != nil {
				return _oops.With("job", job).With("run_date", runDate.Format(time.DateOnly)).Wrapf(lastErr, "pipeline marker not confirmed for by deadline")
			}
			return _oops.With("job", job).With("run_date", runDate.Format(time.DateOnly)).Errorf("pipeline marker not found for by deadline")
		}
		if err := sleep(ctx, interval); err != nil {
			return err
		}
	}
}

// SleepCtx waits d or returns ctx.Err() if ctx is done first. It is the
// production sleep implementation passed to Wait.
func SleepCtx(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(d):
		return nil
	}
}

// NewPGReader reads markers from the env-schema pool.
func NewPGReader(db *pgxpool.Pool) PGReader { return PGReader{db: db} }
