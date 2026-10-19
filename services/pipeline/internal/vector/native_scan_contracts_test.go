package vector

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/pashagolub/pgxmock/v4"
)

type vectorScanFailureDB struct {
	*vectorBatchRecorder
	failedQuery string
	failure     error
}

func (db *vectorScanFailureDB) Query(ctx context.Context, query string, args ...any) (pgx.Rows, error) {
	rows, err := db.PgxPoolIface.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	if query == db.failedQuery {
		return failedVectorScanRows{Rows: rows, failure: db.failure}, nil
	}
	return rows, nil
}

func TestChangeToVectorPreservesEachDatasetScanFailure(t *testing.T) {
	const lower = "2026-10-10T00:00:00Z"
	for _, vectorType := range []string{
		"bus_route", "bus_station", "bike_station", "mrt_station", "tra_station", "thsr_station",
	} {
		t.Run(vectorType, func(t *testing.T) {
			pool := newVectorDBMock(t)
			failed := vectorDatasetByType(t, vectorType)
			want := errors.New("original " + vectorType + " scan failure")
			db := &vectorScanFailureDB{
				vectorBatchRecorder: &vectorBatchRecorder{PgxPoolIface: pool},
				failedQuery:         failed.query,
				failure:             want,
			}
			for _, dataset := range _vectorDatasets {
				rows := pool.NewRows([]string{"unscanned"})
				if dataset.vectorType == vectorType {
					rows.AddRow("pending row")
				}
				pool.ExpectQuery(dataset.query).
					WithArgs(dataset.queryArgs(lower, pgxmock.AnyArg())...).
					WillReturnRows(rows).
					RowsWillBeClosed()
				if dataset.vectorType == vectorType {
					break
				}
			}
			cache := &testVectorRedis{value: lower}
			if err := ChangeToVector(context.Background(), cache, db); !errors.Is(err, want) {
				t.Fatalf("scan failure = %v, want original %v", err, want)
			}
			if len(db.batches) != 0 {
				t.Fatalf("failed scan sent %d write batches", len(db.batches))
			}
			if len(cache.setValues) != 0 {
				t.Fatalf("failed scan attempted watermark writes: %v", cache.setValues)
			}
			if err := pool.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
