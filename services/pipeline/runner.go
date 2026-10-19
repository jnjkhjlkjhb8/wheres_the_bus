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
	connect := resolveStaticPipelineConnect(c.connect)
	conn, err := connect(ctx, c.pool.Config().ConnConfig.Copy())
	if err != nil {
		return nil, nil, _oops.Wrapf(err, "connect static pipeline advisory database")
	}
	if conn == nil {
		return nil, nil, errors.New("connect static pipeline advisory database returned nil connection")
	}
	return conn, closeStaticPipelineConnection(conn), nil
}

func resolveStaticPipelineConnect(connect func(context.Context, *pgx.ConnConfig) (staticPipelineDedicatedConn, error)) func(context.Context, *pgx.ConnConfig) (staticPipelineDedicatedConn, error) {
	if connect != nil {
		return connect
	}
	return func(ctx context.Context, cfg *pgx.ConnConfig) (staticPipelineDedicatedConn, error) {
		return pgx.ConnectConfig(ctx, cfg)
	}
}

func closeStaticPipelineConnection(conn staticPipelineDedicatedConn) func() error {
	var once sync.Once
	var closeErr error
	return func() error {
		once.Do(func() {
			releaseCtx, cancel := context.WithTimeout(context.Background(), _staticPipelineReleaseTimeout)
			defer cancel()
			if err := conn.Close(releaseCtx); err != nil {
				closeErr = _oops.Wrapf(err, "close static pipeline advisory connection")
			}
		})
		return closeErr
	}
}

type pgStaticPipelineLocker struct{ connector staticPipelineConnector }

func (l pgStaticPipelineLocker) Acquire(ctx context.Context) (func() error, error) {
	tx, closeConnection, err := openStaticPipelineTransaction(ctx, l.connector)
	if err != nil {
		return nil, err
	}
	if err := lockStaticPipelineTransaction(ctx, tx, closeConnection); err != nil {
		return nil, err
	}
	return releaseStaticPipelineTransaction(tx, closeConnection), nil
}

func openStaticPipelineTransaction(ctx context.Context, connector staticPipelineConnector) (pgx.Tx, func() error, error) {
	conn, closeConnection, err := connectStaticPipeline(ctx, connector)
	if err != nil {
		return nil, nil, err
	}
	return beginStaticPipelineTransaction(ctx, conn, closeConnection)
}

func connectStaticPipeline(ctx context.Context, connector staticPipelineConnector) (staticPipelineTxBeginner, func() error, error) {
	if connector == nil {
		return nil, nil, errors.New("static pipeline raw lock connector is nil")
	}
	return connector.Connect(ctx)
}

func beginStaticPipelineTransaction(ctx context.Context, conn staticPipelineTxBeginner, closeConnection func() error) (pgx.Tx, func() error, error) {
	if err := validateStaticPipelineConnection(conn, closeConnection); err != nil {
		return nil, nil, err
	}
	tx, err := conn.Begin(ctx)
	if err != nil {
		return nil, nil, errors.Join(_oops.Wrapf(err, "begin static pipeline advisory transaction"), closeConnection())
	}
	return tx, closeConnection, nil
}

func lockStaticPipelineTransaction(ctx context.Context, tx pgx.Tx, closeConnection func() error) error {
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", _staticPipelineAdvisoryKey); err != nil {
		return errors.Join(_oops.Wrapf(err, "acquire static pipeline advisory lock"), rollbackStaticPipelineTx(tx), closeConnection())
	}
	return nil
}

func releaseStaticPipelineTransaction(tx pgx.Tx, closeConnection func() error) func() error {
	var once sync.Once
	var releaseErr error
	return func() error {
		once.Do(func() {
			releaseCtx, cancel := context.WithTimeout(context.Background(), _staticPipelineReleaseTimeout)
			defer cancel()
			if err := tx.Commit(releaseCtx); err != nil {
				releaseErr = errors.Join(_oops.Wrapf(err, "release static pipeline advisory lock"), rollbackStaticPipelineTx(tx))
			}
			releaseErr = errors.Join(releaseErr, closeConnection())
		})
		return releaseErr
	}
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
	ctx, cancel := staticPipelineContext(parent, r.timeout)
	defer cancel()
	leaveGate, err := enterStaticPipelineGate(ctx, r.gate)
	if err != nil {
		return err
	}
	defer leaveGate()
	release, err := acquireStaticPipelineRelease(ctx, r.locker)
	if err != nil {
		return err
	}
	defer func() {
		releaseErr := release()
		err = finishStaticPipelineJob(err, releaseErr, recover())
	}()
	jobErr := job(ctx)
	// A job may fail to cooperate with cancellation and return nil after the
	// deadline. Never report that run as successful; preserve both a real job
	// failure and the deadline/cancellation signal when both are present.
	return errors.Join(jobErr, ctx.Err())
}

func staticPipelineContext(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if parent == nil {
		parent = context.Background()
	}
	return context.WithTimeout(parent, timeout)
}

func enterStaticPipelineGate(ctx context.Context, gate chan struct{}) (func(), error) {
	if gate == nil {
		return nil, errors.New("static pipeline process gate is nil")
	}
	select {
	case gate <- struct{}{}:
		return func() { <-gate }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func acquireStaticPipelineRelease(ctx context.Context, locker staticPipelineLocker) (func() error, error) {
	if locker == nil {
		return nil, errors.New("static pipeline advisory locker is nil")
	}
	release, err := locker.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	return validateStaticPipelineRelease(release)
}

func validateStaticPipelineRelease(release func() error) (func() error, error) {
	if release == nil {
		return nil, errors.New("static pipeline advisory locker returned nil release")
	}
	return release, nil
}

func vectorRefreshJob(rc vector.Redis, db vector.DB) func(context.Context) error {
	return func(ctx context.Context) error {
		return vector.ChangeToVector(ctx, rc, db)
	}
}

func rollbackStaticPipelineTx(tx pgx.Tx) error {
	releaseCtx, cancel := context.WithTimeout(context.Background(), _staticPipelineReleaseTimeout)
	defer cancel()
	err := tx.Rollback(releaseCtx)
	if errors.Is(err, pgx.ErrTxClosed) {
		return nil
	}
	return err
}

func finishStaticPipelineJob(err, releaseErr error, recovered any) error {
	if recovered != nil {
		if releaseErr != nil {
			panic(errors.Join(_oops.With("recovered", recovered).Errorf("static pipeline job panic"), releaseErr))
		}
		panic(recovered)
	}
	return errors.Join(err, releaseErr)
}

func validateStaticPipelineConnection(conn staticPipelineTxBeginner, closeConnection func() error) error {
	if conn == nil || closeConnection == nil {
		closeIncompleteStaticPipelineConnection(closeConnection)
		return errors.New("static pipeline connector returned incomplete connection")
	}
	return nil
}

func closeIncompleteStaticPipelineConnection(closeConnection func() error) {
	if closeConnection != nil {
		_ = closeConnection()
	}
}
