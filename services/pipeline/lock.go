package main

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/marker"
)

// _pipelineRunLockKey serializes whole nightly and hourly runs across Pods. It
// differs from _staticPipelineAdvisoryKey, which each step takes on its own
// for the length of that step: a run must hold this one from its first step to
// its last, so another run cannot slip in between two of its steps.
const _pipelineRunLockKey int64 = 0x627573706970656c

// errRunLockBusy means another nightly or hourly run holds the run lock.
var errRunLockBusy = errors.New("pipeline run lock held by another run")

// runLock holds a session-level advisory lock on a dedicated connection, so the
// pool's connections stay free for the steps themselves.
type runLock struct {
	conn *pgx.Conn
}

// acquireRunLock tries for the run lock every retry until wait has passed. A
// zero wait tries exactly once.
func acquireRunLock(ctx context.Context, pool *pgxpool.Pool, wait, retry time.Duration) (*runLock, error) {
	conn, err := pgx.ConnectConfig(ctx, pool.Config().ConnConfig.Copy())
	if err != nil {
		return nil, _oops.Wrapf(err, "connect pipeline run lock")
	}
	lock, err := waitForPipelineRunLock(ctx, conn, time.Now().Add(wait), retry)
	if err != nil {
		_ = conn.Close(context.Background())
	}
	return lock, err
}

func waitForPipelineRunLock(ctx context.Context, conn *pgx.Conn, deadline time.Time, retry time.Duration) (*runLock, error) {
	for {
		acquired, err := tryPipelineRunLock(ctx, conn, deadline, retry)
		if err != nil {
			return nil, err
		}
		if acquired {
			return &runLock{conn: conn}, nil
		}
	}
}

func tryPipelineRunLock(ctx context.Context, conn *pgx.Conn, deadline time.Time, retry time.Duration) (bool, error) {
	var acquired bool
	if err := conn.QueryRow(ctx, "SELECT pg_try_advisory_lock($1)", _pipelineRunLockKey).Scan(&acquired); err != nil {
		return false, _oops.Wrapf(err, "try pipeline run lock")
	}
	if acquired {
		return true, nil
	}
	return false, waitPipelineRunLockRetry(ctx, deadline, retry)
}

func waitPipelineRunLockRetry(ctx context.Context, deadline time.Time, retry time.Duration) error {
	if !time.Now().Add(retry).Before(deadline) {
		return errRunLockBusy
	}
	return marker.SleepCtx(ctx, retry)
}

// release drops the lock by closing its connection; the server frees a
// session lock when the session ends.
func (l *runLock) release() error {
	ctx, cancel := context.WithTimeout(context.Background(), _staticPipelineReleaseTimeout)
	defer cancel()
	return l.conn.Close(ctx)
}
