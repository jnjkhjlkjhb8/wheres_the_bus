package main

import (
	"context"
	"errors"
	"regexp"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

type fakeStaticLocker struct {
	acquire func(context.Context) (func() error, error)
}

func (f fakeStaticLocker) Acquire(ctx context.Context) (func() error, error) {
	return f.acquire(ctx)
}

type fakeStaticConnector struct {
	connect func(context.Context) (staticPipelineTxBeginner, func() error, error)
}

func (f fakeStaticConnector) Connect(ctx context.Context) (staticPipelineTxBeginner, func() error, error) {
	return f.connect(ctx)
}

type fakeDedicatedConn struct {
	beginner staticPipelineTxBeginner
	closeErr error
	closes   *atomic.Int64
}

func (c fakeDedicatedConn) Begin(ctx context.Context) (pgx.Tx, error) {
	return c.beginner.Begin(ctx)
}

func (c fakeDedicatedConn) Close(context.Context) error {
	if c.closes != nil {
		c.closes.Add(1)
	}
	return c.closeErr
}

func noOpStaticLocker() staticPipelineLocker {
	return fakeStaticLocker{acquire: func(context.Context) (func() error, error) {
		return func() error { return nil }, nil
	}}
}

func observeConcurrency(active, maximum *atomic.Int64, hold time.Duration) func(context.Context) error {
	return func(ctx context.Context) error {
		n := active.Add(1)
		defer active.Add(-1)
		for {
			old := maximum.Load()
			if n <= old || maximum.CompareAndSwap(old, n) {
				break
			}
		}
		select {
		case <-time.After(hold):
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func TestStaticPipelineLockSerializesBootCronAndVector(t *testing.T) {
	gate := make(chan struct{}, 1)
	runner := staticPipelineRunner{gate: gate, locker: noOpStaticLocker(), timeout: time.Second}
	var active, maximum atomic.Int64
	job := observeConcurrency(&active, &maximum, 15*time.Millisecond)
	var wg sync.WaitGroup
	errCh := make(chan error, 3)
	for range 3 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errCh <- runner.Run(context.Background(), job)
		}()
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			t.Fatalf("runner returned %v", err)
		}
	}
	if maximum.Load() != 1 {
		t.Fatalf("maximum concurrent static jobs = %d, want 1", maximum.Load())
	}
}

func TestStaticPipelineAdvisoryLockSerializesContainers(t *testing.T) {
	databaseGate := make(chan struct{}, 1)
	locker := fakeStaticLocker{acquire: func(ctx context.Context) (func() error, error) {
		select {
		case databaseGate <- struct{}{}:
			return func() error { <-databaseGate; return nil }, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}}
	runners := []staticPipelineRunner{
		{gate: make(chan struct{}, 1), locker: locker, timeout: time.Second},
		{gate: make(chan struct{}, 1), locker: locker, timeout: time.Second},
	}
	var active, maximum atomic.Int64
	job := observeConcurrency(&active, &maximum, 20*time.Millisecond)
	errCh := make(chan error, 2)
	for i := range runners {
		go func(r staticPipelineRunner) { errCh <- r.Run(context.Background(), job) }(runners[i])
	}
	for range runners {
		if err := <-errCh; err != nil {
			t.Fatalf("runner returned %v", err)
		}
	}
	if maximum.Load() != 1 {
		t.Fatalf("maximum cross-runner concurrency = %d, want 1", maximum.Load())
	}
}

func TestStaticPipelineUsesSharedRawLockerForDifferentTargets(t *testing.T) {
	// The two jobs model distinct environment target pools. They deliberately
	// share only the raw-source locker; target identity must not select the lock.
	type targetPool struct{ calls atomic.Int64 }
	targets := []*targetPool{{}, {}}
	rawGate := make(chan struct{}, 1)
	rawLocker := fakeStaticLocker{acquire: func(ctx context.Context) (func() error, error) {
		select {
		case rawGate <- struct{}{}:
			return func() error { <-rawGate; return nil }, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}}
	var active, maximum atomic.Int64
	errCh := make(chan error, len(targets))
	for _, target := range targets {
		runner := staticPipelineRunner{
			gate: make(chan struct{}, 1), locker: rawLocker, timeout: time.Second,
		}
		go func(target *targetPool) {
			errCh <- runner.Run(context.Background(), func(ctx context.Context) error {
				target.calls.Add(1)
				return observeConcurrency(&active, &maximum, 20*time.Millisecond)(ctx)
			})
		}(target)
	}
	for range targets {
		if err := <-errCh; err != nil {
			t.Fatalf("runner returned %v", err)
		}
	}
	if maximum.Load() != 1 {
		t.Fatalf("different target pools overlapped: maximum=%d", maximum.Load())
	}
	for i, target := range targets {
		if target.calls.Load() != 1 {
			t.Fatalf("target %d calls = %d, want 1", i, target.calls.Load())
		}
	}
}

func TestBootRunUsesTimeoutAndSameOverlapGuard(t *testing.T) {
	t.Run("timeout", func(t *testing.T) {
		runner := staticPipelineRunner{
			gate: make(chan struct{}, 1), locker: noOpStaticLocker(), timeout: 30 * time.Millisecond,
		}
		err := runner.Run(context.Background(), func(ctx context.Context) error {
			<-ctx.Done()
			return ctx.Err()
		})
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("boot error = %v, want DeadlineExceeded", err)
		}
	})

	t.Run("deadline is reported when job returns nil late", func(t *testing.T) {
		runner := staticPipelineRunner{
			gate: make(chan struct{}, 1), locker: noOpStaticLocker(), timeout: 15 * time.Millisecond,
		}
		err := runner.Run(context.Background(), func(context.Context) error {
			time.Sleep(30 * time.Millisecond)
			return nil
		})
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("late nil job error = %v, want DeadlineExceeded", err)
		}
	})

	t.Run("shared overlap guard", func(t *testing.T) {
		runner := staticPipelineRunner{
			gate: make(chan struct{}, 1), locker: noOpStaticLocker(), timeout: time.Second,
		}
		started := make(chan struct{})
		releaseFirst := make(chan struct{})
		firstDone := make(chan error, 1)
		go func() {
			firstDone <- runner.Run(context.Background(), func(context.Context) error {
				close(started)
				<-releaseFirst
				return nil
			})
		}()
		<-started
		secondRan := atomic.Bool{}
		secondCtx, cancelSecond := context.WithTimeout(context.Background(), 30*time.Millisecond)
		defer cancelSecond()
		secondErr := runner.Run(secondCtx, func(context.Context) error {
			secondRan.Store(true)
			return nil
		})
		if !errors.Is(secondErr, context.DeadlineExceeded) {
			t.Fatalf("overlapping boot/cron error = %v, want DeadlineExceeded", secondErr)
		}
		if secondRan.Load() {
			t.Fatal("overlapping job ran despite shared guard")
		}
		close(releaseFirst)
		if err := <-firstDone; err != nil {
			t.Fatalf("first job error = %v", err)
		}
	})
}

func TestPGStaticPipelineLockerUsesTransactionScopedAdvisoryLock(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectBegin()
	db.ExpectExec(regexp.QuoteMeta("SELECT pg_advisory_xact_lock($1)")).
		WithArgs(_staticPipelineAdvisoryKey).
		WillReturnResult(pgxmock.NewResult("SELECT", 1))
	db.ExpectCommit()
	var closes atomic.Int64
	connector := fakeStaticConnector{connect: func(context.Context) (staticPipelineTxBeginner, func() error, error) {
		return db, func() error { closes.Add(1); return nil }, nil
	}}

	release, err := (pgStaticPipelineLocker{connector: connector}).Acquire(context.Background())
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := release(); err != nil {
		t.Fatalf("release: %v", err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
	if closes.Load() != 1 {
		t.Fatalf("dedicated connection closes = %d, want 1", closes.Load())
	}
}

func TestStaticPipelineDedicatedLockLeavesMaxOneJobPoolSlotAvailable(t *testing.T) {
	cfg, err := pgxpool.ParseConfig("postgres://test:test@127.0.0.1:1/test")
	if err != nil {
		t.Fatal(err)
	}
	cfg.MaxConns = 1
	jobPool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer jobPool.Close()

	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectBegin()
	db.ExpectExec(regexp.QuoteMeta("SELECT pg_advisory_xact_lock($1)")).
		WithArgs(_staticPipelineAdvisoryKey).
		WillReturnResult(pgxmock.NewResult("SELECT", 1))
	db.ExpectCommit()
	var connects, closes atomic.Int64
	connector := pgStaticPipelineConnector{
		pool: jobPool,
		connect: func(_ context.Context, copied *pgx.ConnConfig) (staticPipelineDedicatedConn, error) {
			connects.Add(1)
			copied.Database = "mutated-copy"
			return fakeDedicatedConn{beginner: db, closes: &closes}, nil
		},
	}
	runner := staticPipelineRunner{
		gate:    make(chan struct{}, 1),
		locker:  pgStaticPipelineLocker{connector: connector},
		timeout: time.Second,
	}
	// This single-slot semaphore models the MaxConns=1 job pool. The dedicated
	// connector must not consume it while holding the advisory transaction.
	jobSlot := make(chan struct{}, 1)
	err = runner.Run(context.Background(), func(context.Context) error {
		select {
		case jobSlot <- struct{}{}:
			<-jobSlot
			return nil
		default:
			return errors.New("job pool's only slot was consumed by advisory lock")
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if connects.Load() != 1 || closes.Load() != 1 {
		t.Fatalf("dedicated connection lifecycle = %d connects/%d closes, want 1/1", connects.Load(), closes.Load())
	}
	if got := jobPool.Stat().AcquiredConns(); got != 0 {
		t.Fatalf("advisory locker acquired %d pooled connections, want 0", got)
	}
	if got := jobPool.Config().ConnConfig.Database; got != "test" {
		t.Fatalf("connector mutated raw pool config database to %q", got)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPGStaticPipelineLockerClosesDedicatedConnectionOnBeginAndLockFailure(t *testing.T) {
	t.Run("begin", func(t *testing.T) {
		db, err := pgxmock.NewPool()
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		beginErr := errors.New("begin failed")
		db.ExpectBegin().WillReturnError(beginErr)
		var closes atomic.Int64
		locker := pgStaticPipelineLocker{connector: fakeStaticConnector{
			connect: func(context.Context) (staticPipelineTxBeginner, func() error, error) {
				return db, func() error { closes.Add(1); return nil }, nil
			},
		}}
		if _, err := locker.Acquire(context.Background()); !errors.Is(err, beginErr) {
			t.Fatalf("begin error = %v, want %v", err, beginErr)
		}
		if closes.Load() != 1 {
			t.Fatalf("connection closes = %d, want 1", closes.Load())
		}
		if err := db.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("lock", func(t *testing.T) {
		db, err := pgxmock.NewPool()
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		lockErr := errors.New("lock failed")
		db.ExpectBegin()
		db.ExpectExec(regexp.QuoteMeta("SELECT pg_advisory_xact_lock($1)")).
			WithArgs(_staticPipelineAdvisoryKey).
			WillReturnError(lockErr)
		db.ExpectRollback()
		var closes atomic.Int64
		locker := pgStaticPipelineLocker{connector: fakeStaticConnector{
			connect: func(context.Context) (staticPipelineTxBeginner, func() error, error) {
				return db, func() error { closes.Add(1); return nil }, nil
			},
		}}
		if _, err := locker.Acquire(context.Background()); !errors.Is(err, lockErr) {
			t.Fatalf("lock error = %v, want %v", err, lockErr)
		}
		if closes.Load() != 1 {
			t.Fatalf("connection closes = %d, want 1", closes.Load())
		}
		if err := db.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
}

func TestPGStaticPipelineLockerReturnsConnectCommitAndCloseErrors(t *testing.T) {
	connectErr := errors.New("dedicated connect failed")
	locker := pgStaticPipelineLocker{connector: fakeStaticConnector{
		connect: func(context.Context) (staticPipelineTxBeginner, func() error, error) {
			return nil, nil, connectErr
		},
	}}
	if _, err := locker.Acquire(context.Background()); !errors.Is(err, connectErr) {
		t.Fatalf("connect error = %v, want %v", err, connectErr)
	}

	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	commitErr := errors.New("advisory commit failed")
	closeErr := errors.New("dedicated close failed")
	db.ExpectBegin()
	db.ExpectExec(regexp.QuoteMeta("SELECT pg_advisory_xact_lock($1)")).
		WithArgs(_staticPipelineAdvisoryKey).
		WillReturnResult(pgxmock.NewResult("SELECT", 1))
	db.ExpectCommit().WillReturnError(commitErr)
	db.ExpectRollback()
	cfg, err := pgxpool.ParseConfig("postgres://test:test@127.0.0.1:1/test")
	if err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	locker.connector = pgStaticPipelineConnector{
		pool: pool,
		connect: func(context.Context, *pgx.ConnConfig) (staticPipelineDedicatedConn, error) {
			return fakeDedicatedConn{beginner: db, closeErr: closeErr}, nil
		},
	}
	release, err := locker.Acquire(context.Background())
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	err = release()
	if !errors.Is(err, commitErr) || !errors.Is(err, closeErr) {
		t.Fatalf("release error = %v, want commit %v and close %v", err, commitErr, closeErr)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestStaticPipelineReleasesAfterCancellationAndPanic(t *testing.T) {
	var releases atomic.Int64
	locker := fakeStaticLocker{acquire: func(context.Context) (func() error, error) {
		return func() error { releases.Add(1); return nil }, nil
	}}
	runner := staticPipelineRunner{
		gate: make(chan struct{}, 1), locker: locker, timeout: 20 * time.Millisecond,
	}
	err := runner.Run(context.Background(), func(ctx context.Context) error {
		<-ctx.Done()
		return ctx.Err()
	})
	if !errors.Is(err, context.DeadlineExceeded) || releases.Load() != 1 {
		t.Fatalf("canceled run error=%v releases=%d, want deadline/1", err, releases.Load())
	}

	runner.timeout = time.Second
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("runner did not rethrow job panic")
			}
		}()
		_ = runner.Run(context.Background(), func(context.Context) error {
			panic("job exploded")
		})
	}()
	if releases.Load() != 2 {
		t.Fatalf("releases after panic = %d, want 2", releases.Load())
	}
}

func TestStaticPipelineReturnsAcquireAndReleaseErrors(t *testing.T) {
	acquireErr := errors.New("advisory lock failed")
	runner := staticPipelineRunner{
		gate: make(chan struct{}, 1), timeout: time.Second,
		locker: fakeStaticLocker{acquire: func(context.Context) (func() error, error) {
			return nil, acquireErr
		}},
	}
	if err := runner.Run(context.Background(), func(context.Context) error { return nil }); !errors.Is(err, acquireErr) {
		t.Fatalf("acquire error = %v, want %v", err, acquireErr)
	}

	releaseErr := errors.New("advisory unlock failed")
	jobErr := errors.New("static job failed")
	runner.locker = fakeStaticLocker{acquire: func(context.Context) (func() error, error) {
		return func() error { return releaseErr }, nil
	}}
	err := runner.Run(context.Background(), func(context.Context) error { return jobErr })
	if !errors.Is(err, jobErr) || !errors.Is(err, releaseErr) {
		t.Fatalf("combined job/release error = %v, want %v and %v", err, jobErr, releaseErr)
	}
}
