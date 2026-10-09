// Package cleanup enforces retention on the tables that grow without bound:
// prediction-error rows past their window are deleted so the archive database
// stays within its disk budget.
package cleanup

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"go.uber.org/zap"
)

// retentionDB is the narrow Postgres exec seam the retention job needs.
// *pgxpool.Pool satisfies it structurally; unit tests drive the job through a
// pgxmock pool instead of a live database.
type retentionDB interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

const _cleanupBatchSize = 5000

func batchDeleteOlderThan(ctx context.Context, db retentionDB, table, cutoffColumn, retention string) (int64, error) {
	sql := fmt.Sprintf(`
		WITH victims AS (
			SELECT ctid FROM %s WHERE %s < NOW() - INTERVAL '%s' LIMIT $1
		)
		DELETE FROM %s WHERE ctid IN (SELECT ctid FROM victims)`,
		table, cutoffColumn, retention, table)

	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		tag, err := db.Exec(ctx, sql, _cleanupBatchSize)
		if err != nil {
			return total, err
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < _cleanupBatchSize {
			return total, nil
		}
	}
}

func PredictionErrors(ctx context.Context, db retentionDB) error {
	deleted, err := batchDeleteOlderThan(ctx, db, "bus_eta_prediction_error", "predicted_at", "30 days")
	if err != nil {
		// deleted is the count from the batches that did land before the failure.
		return obs.Transient(_oops.With("deleted", deleted).Wrapf(err, "cleanup prediction error after rows"))
	}
	zap.S().Infow("cleanup deleted rows", "component", "eta_error", "rows", deleted)
	return nil
}
