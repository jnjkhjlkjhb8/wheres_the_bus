package vector

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/pashagolub/pgxmock/v4"
)

type vectorBatchRecorder struct {
	pgxmock.PgxPoolIface
	batches []*pgx.Batch
	err     error
}

func (db *vectorBatchRecorder) SendBatch(_ context.Context, batch *pgx.Batch) pgx.BatchResults {
	db.batches = append(db.batches, batch)
	return closeErrorBatchResults{db.err}
}

func TestVectorDatasetFlushesCompleteBatchAndTailInOrder(t *testing.T) {
	for _, failed := range []bool{false, true} {
		pool := newVectorDBMock(t)
		dataset := vectorDatasetByType(t, "bus_route")
		cutoff := time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)
		rows := pool.NewRows([]string{"sub_route_uid", "sub_route_name", "city", "depart", "destin"})
		for i := range _size + 1 {
			rows.AddRow(fmt.Sprintf("R%d", i), "藍線", "Taipei", "台北車站", "市政府")
		}
		pool.ExpectQuery(dataset.query).WithArgs(dataset.queryArgs("lower", cutoff)...).WillReturnRows(rows)
		db := &vectorBatchRecorder{PgxPoolIface: pool}
		if failed {
			db.err = errors.New("full batch write failed")
		}
		err := processVectorDataset(context.Background(), db, dataset, "lower", cutoff)
		if failed {
			if !errors.Is(err, db.err) || len(db.batches) != 1 {
				t.Fatalf("failure: %v, batches %d", err, len(db.batches))
			}
		} else {
			if err != nil {
				t.Fatal(err)
			}
			if len(db.batches) != 2 || db.batches[0].Len() != _size || db.batches[1].Len() != 1 {
				t.Fatalf("batch partition = %#v", db.batches)
			}
			if db.batches[0].QueuedQueries[0].Arguments[1] != "R0" || db.batches[1].QueuedQueries[0].Arguments[1] != fmt.Sprintf("R%d", _size) {
				t.Fatal("batch boundary reordered or lost rows")
			}
		}
		if err := pool.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestVectorDatasetPreservesTerminalRowsError(t *testing.T) {
	pool := newVectorDBMock(t)
	dataset := vectorDatasetByType(t, "bus_route")
	cutoff := time.Now()
	want := errors.New("connection lost while reading")
	rows := validBusVectorRows(pool).AddRow("R2", "藍線", "Taipei", "台北車站", "市政府").CloseError(want)
	pool.ExpectQuery(dataset.query).WithArgs(dataset.queryArgs("lower", cutoff)...).WillReturnRows(rows)
	db := &vectorBatchRecorder{PgxPoolIface: pool}
	if err := processVectorDataset(context.Background(), db, dataset, "lower", cutoff); !errors.Is(err, want) {
		t.Fatalf("error = %v", err)
	}
	if len(db.batches) != 0 {
		t.Fatal("incomplete read wrote tail")
	}
	if err := pool.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestVectorCacheReadFailurePreventsAllWork(t *testing.T) {
	want := errors.New("Redis unavailable")
	cache := &testVectorRedis{getErr: want}
	if err := ChangeToVector(context.Background(), cache, nil); !errors.Is(err, want) {
		t.Fatalf("error = %v", err)
	}
	if len(cache.setValues) != 0 {
		t.Fatal("failed read advanced watermark")
	}
}

type failedVectorScanRows struct {
	pgx.Rows
	failure error
}

func (rows failedVectorScanRows) Scan(...any) error { return rows.failure }

func TestVectorDatasetScanFailurePreventsWrites(t *testing.T) {
	pool := newVectorDBMock(t)
	pool.ExpectQuery("SELECT vector_rows").WillReturnRows(validBusVectorRows(pool))
	rows, err := pool.Query(context.Background(), "SELECT vector_rows")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	want := errors.New("invalid vector row scan")
	db := &vectorBatchRecorder{PgxPoolIface: pool}
	builder := vectorBatchBuilder{ctx: context.Background(), db: db, dataset: vectorDatasetByType(t, "bus_route")}
	if err := builder.consume(failedVectorScanRows{Rows: rows, failure: want}); !errors.Is(err, want) {
		t.Fatalf("scan failure = %v", err)
	}
	if len(db.batches) != 0 {
		t.Fatal("failed scan wrote a batch")
	}
	if err := pool.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestVectorWatermarkPreservesExistingWindow(t *testing.T) {
	want := "2026-10-09T14:32:10Z"
	got, err := readVectorWatermark(context.Background(), &testVectorRedis{value: want})
	if err != nil || got != want {
		t.Fatalf("watermark = %q, %v", got, err)
	}
}

func TestVectorWatermarkStartsAtBeginningForEmptyCache(t *testing.T) {
	got, err := readVectorWatermark(context.Background(), &testVectorRedis{})
	if err != nil || got != (time.Time{}).Format(time.RFC3339) {
		t.Fatalf("initial watermark = %q, %v", got, err)
	}
}
