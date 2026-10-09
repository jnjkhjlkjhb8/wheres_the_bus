package main

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/vector"
)

const (
	// Stable, repo-specific signed 64-bit key shared by every pipeline run.
	_staticPipelineAdvisoryKey    int64 = 0x6275737374617469
	_staticPipelineReleaseTimeout       = 5 * time.Second
)

// _manualBackfillTimeout bounds the `functions run changetovector` one-shot. It
// is deliberately far larger than the cron's per-attempt 10m budget so a cold
// full-corpus backfill on a CPU/small-GPU embedder completes in one pass.

// staticPipelineLocker holds a cross-process lock until its release callback.
// The PostgreSQL implementation below uses a transaction-scoped advisory lock;
// this narrow seam keeps concurrency tests independent of a live database.
type staticPipelineLocker interface {
	Acquire(context.Context) (release func() error, err error)
}

type staticPipelineTxBeginner interface {
	Begin(context.Context) (pgx.Tx, error)
}

type staticPipelineConnector interface {
	Connect(context.Context) (staticPipelineTxBeginner, func() error, error)
}

type staticPipelineDedicatedConn interface {
	staticPipelineTxBeginner
	Close(context.Context) error
}

// A separate connection prevents advisory locking from exhausting a one-connection job pool.
type pgStaticPipelineConnector struct {
	pool    *pgxpool.Pool
	connect func(context.Context, *pgx.ConnConfig) (staticPipelineDedicatedConn, error)
}

func (c pgStaticPipelineConnector) Connect(ctx context.Context) (staticPipelineTxBeginner, func() error, error) {
	if c.pool == nil {
		return nil, nil, errors.New("static pipeline raw lock pool is nil")
	}
	connect := c.connect
	if connect == nil {
		connect = func(ctx context.Context, cfg *pgx.ConnConfig) (staticPipelineDedicatedConn, error) {
			return pgx.ConnectConfig(ctx, cfg)
		}
	}
	conn, err := connect(ctx, c.pool.Config().ConnConfig.Copy())
	if err != nil {
		return nil, nil, _oops.Wrapf(err, "connect static pipeline advisory database")
	}
	if conn == nil {
		return nil, nil, errors.New("connect static pipeline advisory database returned nil connection")
	}
	var once sync.Once
	var closeErr error
	closeConnection := func() error {
		once.Do(func() {
			releaseCtx, cancel := context.WithTimeout(context.Background(), _staticPipelineReleaseTimeout)
			defer cancel()
			if err := conn.Close(releaseCtx); err != nil {
				closeErr = _oops.Wrapf(err, "close static pipeline advisory connection")
			}
		})
		return closeErr
	}
	return conn, closeConnection, nil
}

type pgStaticPipelineLocker struct{ connector staticPipelineConnector }

func (l pgStaticPipelineLocker) Acquire(ctx context.Context) (func() error, error) {
	if l.connector == nil {
		return nil, errors.New("static pipeline raw lock connector is nil")
	}
	conn, closeConnection, err := l.connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	if conn == nil || closeConnection == nil {
		if closeConnection != nil {
			_ = closeConnection()
		}
		return nil, errors.New("static pipeline connector returned incomplete connection")
	}
	tx, err := conn.Begin(ctx)
	if err != nil {
		return nil, errors.Join(
			_oops.Wrapf(err, "begin static pipeline advisory transaction"),
			closeConnection(),
		)
	}
	rollback := func() error {
		releaseCtx, cancel := context.WithTimeout(context.Background(), _staticPipelineReleaseTimeout)
		defer cancel()
		err := tx.Rollback(releaseCtx)
		if errors.Is(err, pgx.ErrTxClosed) {
			return nil
		}
		return err
	}
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", _staticPipelineAdvisoryKey); err != nil {
		return nil, errors.Join(
			_oops.Wrapf(err, "acquire static pipeline advisory lock"),
			rollback(),
			closeConnection(),
		)
	}
	var once sync.Once
	var releaseErr error
	return func() error {
		once.Do(func() {
			releaseCtx, cancel := context.WithTimeout(context.Background(), _staticPipelineReleaseTimeout)
			defer cancel()
			if err := tx.Commit(releaseCtx); err != nil {
				releaseErr = errors.Join(
					_oops.Wrapf(err, "release static pipeline advisory lock"),
					rollback(),
				)
			}
			releaseErr = errors.Join(releaseErr, closeConnection())
		})
		return releaseErr
	}, nil
}

// One process-wide gate serializes boot, cron, and manual static work. Separate
// containers have separate gates and are serialized by pgStaticPipelineLocker.
var _staticPipelineProcessGate = make(chan struct{}, 1)

type staticPipelineRunner struct {
	gate    chan struct{}
	locker  staticPipelineLocker
	timeout time.Duration
}

func newStaticPipelineRunner(rawLockPool *pgxpool.Pool, timeout time.Duration) staticPipelineRunner {
	return staticPipelineRunner{
		gate: _staticPipelineProcessGate,
		locker: pgStaticPipelineLocker{connector: pgStaticPipelineConnector{
			pool: rawLockPool,
		}},
		timeout: timeout,
	}
}

func (r staticPipelineRunner) Run(parent context.Context, job func(context.Context) error) (err error) {
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, r.timeout)
	defer cancel()
	if r.gate == nil {
		return errors.New("static pipeline process gate is nil")
	}
	select {
	case r.gate <- struct{}{}:
		defer func() { <-r.gate }()
	case <-ctx.Done():
		return ctx.Err()
	}
	if r.locker == nil {
		return errors.New("static pipeline advisory locker is nil")
	}
	release, err := r.locker.Acquire(ctx)
	if err != nil {
		return err
	}
	if release == nil {
		return errors.New("static pipeline advisory locker returned nil release")
	}
	defer func() {
		releaseErr := release()
		if recovered := recover(); recovered != nil {
			if releaseErr != nil {
				panic(errors.Join(_oops.With("recovered", recovered).Errorf("static pipeline job panic"), releaseErr))
			}
			panic(recovered)
		}
		err = errors.Join(err, releaseErr)
	}()
	jobErr := job(ctx)
	// A job may fail to cooperate with cancellation and return nil after the
	// deadline. Never report that run as successful; preserve both a real job
	// failure and the deadline/cancellation signal when both are present.
	return errors.Join(jobErr, ctx.Err())
}

func vectorRefreshJob(rc vector.Redis, db vector.DB) func(context.Context) error {
	return func(ctx context.Context) error {
		return vector.ChangeToVector(ctx, rc, db)
	}
}
