package cleanup

import (
	"context"
	"errors"
	"regexp"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

// newRetentionMock returns a pgxmock pool using the library's default regexp
// matcher (the batched delete spans multiple lines, so an exact-text matcher
// would be brittle) and fails the test on any unmet expectation.
func newRetentionMock(t *testing.T) pgxmock.PgxPoolIface {
	t.Helper()
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatalf("pgxmock.NewPool: %v", err)
	}
	t.Cleanup(func() {
		if err := db.ExpectationsWereMet(); err != nil {
			t.Errorf("unmet database expectation: %v", err)
		}
		db.Close()
	})
	return db
}

func TestCleanupPredictionErrorsCapsDeleteBatches(t *testing.T) {
	db := newRetentionMock(t)

	perrDelete := regexp.QuoteMeta("bus_eta_prediction_error")
	db.ExpectExec(perrDelete).
		WithArgs(_cleanupBatchSize).
		WillReturnResult(pgxmock.NewResult("DELETE", int64(_cleanupBatchSize)))
	db.ExpectExec(perrDelete).
		WithArgs(_cleanupBatchSize).
		WillReturnResult(pgxmock.NewResult("DELETE", 37))

	if err := PredictionErrors(context.Background(), db); err != nil {
		t.Fatalf("PredictionErrors: %v", err)
	}
}

type cancelAfterExec struct {
	pgxmock.PgxPoolIface
	cancel   context.CancelFunc
	cancelAt int
	execs    int
}

func (d *cancelAfterExec) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	tag, err := d.PgxPoolIface.Exec(ctx, sql, args...)
	d.execs++
	if d.execs == d.cancelAt {
		d.cancel()
	}
	return tag, err
}

func TestCleanupPredictionErrorsStopsOnContextCancellation(t *testing.T) {
	db := newRetentionMock(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	wrapped := &cancelAfterExec{PgxPoolIface: db, cancel: cancel, cancelAt: 1}

	// The first batch reports a full batch, so the loop wants to continue;
	// cancellation lands immediately after, so no second Exec may issue.
	db.ExpectExec(regexp.QuoteMeta("bus_eta_prediction_error")).
		WithArgs(_cleanupBatchSize).
		WillReturnResult(pgxmock.NewResult("DELETE", int64(_cleanupBatchSize)))

	err := PredictionErrors(ctx, wrapped)
	if err == nil {
		t.Fatal("PredictionErrors: want error on context cancellation, got nil")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("PredictionErrors error = %v, want context.Canceled in chain", err)
	}
}

// A delete failure must reach the caller: runDaily gates its retry on the
// returned error, so swallowing it would silently stop retention.
func TestCleanupPredictionErrorsReportsFailure(t *testing.T) {
	db := newRetentionMock(t)
	wantErr := errors.New("connection reset")
	db.ExpectExec(regexp.QuoteMeta("bus_eta_prediction_error")).
		WithArgs(_cleanupBatchSize).
		WillReturnError(wantErr)

	err := PredictionErrors(context.Background(), db)
	if err == nil {
		t.Fatal("PredictionErrors: want error when the delete fails, got nil")
	}
	if !errors.Is(err, wantErr) {
		t.Errorf("PredictionErrors error = %v, want to wrap %v", err, wantErr)
	}
}
