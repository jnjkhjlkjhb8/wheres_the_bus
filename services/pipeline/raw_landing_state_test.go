package main

import (
	"context"
	"errors"
	"regexp"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

const (
	_stateSelectForUpdatePattern = `SELECT last_modified, row_count FROM raw_tdx\.landing_state WHERE table_name=\$1 AND partition_column=\$2 AND partition_value=\$3 FOR UPDATE`
	_stateTouchPattern           = `UPDATE raw_tdx\.landing_state SET fetched_at=now\(\), landing_cycle=\$4 WHERE table_name=\$1 AND partition_column=\$2 AND partition_value=\$3`
	_stateUpsertPattern          = `INSERT INTO raw_tdx\.landing_state .* ON CONFLICT .* DO UPDATE SET .*`
	_stateFreshnessPattern       = `SELECT fetched_at, row_count FROM raw_tdx\.landing_state WHERE table_name=\$1 AND partition_column=\$2 AND partition_value=\$3`
)

func expectStateRead(db pgxmock.PgxPoolIface, marker string, rows int64) {
	db.ExpectQuery(_stateSelectForUpdatePattern).
		WithArgs("bus_route", "city", "Taipei").
		WillReturnRows(pgxmock.NewRows([]string{"last_modified", "row_count"}).AddRow(marker, rows))
}

func TestVerifyAndTouchRawLandingAcceptsMatchingEmptyAndNonEmpty(t *testing.T) {
	for _, tc := range []struct {
		name     string
		rowCount int64
		hasRows  bool
	}{
		{name: "verified empty", rowCount: 0, hasRows: false},
		{name: "matching nonempty", rowCount: 42, hasRows: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db := newRawLandingMock(t)
			db.ExpectBegin()
			db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
				WillReturnResult(pgxmock.NewResult("SET", 0))
			expectStateRead(db, "MARKER", tc.rowCount)
			db.ExpectQuery(regexp.QuoteMeta("SELECT EXISTS (SELECT 1 FROM raw_tdx.bus_route WHERE city = $1 LIMIT 1)")).
				WithArgs("Taipei").
				WillReturnRows(pgxmock.NewRows([]string{"exists"}).AddRow(tc.hasRows))
			db.ExpectExec(_stateTouchPattern).
				WithArgs("bus_route", "city", "Taipei", "cycle-test").
				WillReturnResult(pgxmock.NewResult("UPDATE", 1))
			db.ExpectCommit()

			if err := raw.VerifyAndTouchLandingWithDB(
				context.Background(), db, raw.Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER", "cycle-test",
			); err != nil {
				t.Fatalf("verifyAndTouchRawLandingWithDB: %v", err)
			}
		})
	}
}

func TestVerifyAndTouchRawLandingRejectsMissingMarkerAndPresenceMismatch(t *testing.T) {
	t.Run("missing state", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectBegin()
		db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
			WillReturnResult(pgxmock.NewResult("SET", 0))
		db.ExpectQuery(_stateSelectForUpdatePattern).
			WithArgs("bus_route", "city", "Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"last_modified", "row_count"}))
		db.ExpectRollback()

		err := raw.VerifyAndTouchLandingWithDB(
			context.Background(), db, raw.Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER", "cycle-test",
		)
		assertLandingMismatch(t, err, "missing_state")
	})

	t.Run("marker mismatch", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectBegin()
		db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
			WillReturnResult(pgxmock.NewResult("SET", 0))
		expectStateRead(db, "DB-MARKER", 1)
		db.ExpectRollback()

		err := raw.VerifyAndTouchLandingWithDB(
			context.Background(), db, raw.Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "HTTP-MARKER", "cycle-test",
		)
		assertLandingMismatch(t, err, "marker")
	})

	for _, tc := range []struct {
		name    string
		rows    int64
		hasRows bool
	}{
		{name: "state empty but raw exists", rows: 0, hasRows: true},
		{name: "state nonempty but raw missing", rows: 3, hasRows: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db := newRawLandingMock(t)
			db.ExpectBegin()
			db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
				WillReturnResult(pgxmock.NewResult("SET", 0))
			expectStateRead(db, "MARKER", tc.rows)
			db.ExpectQuery(regexp.QuoteMeta("SELECT EXISTS (SELECT 1 FROM raw_tdx.bus_route WHERE city = $1 LIMIT 1)")).
				WithArgs("Taipei").
				WillReturnRows(pgxmock.NewRows([]string{"exists"}).AddRow(tc.hasRows))
			db.ExpectRollback()

			err := raw.VerifyAndTouchLandingWithDB(
				context.Background(), db, raw.Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER", "cycle-test",
			)
			assertLandingMismatch(t, err, "row_presence")
		})
	}

	t.Run("state touch updates exactly one row", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectBegin()
		db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
			WillReturnResult(pgxmock.NewResult("SET", 0))
		expectStateRead(db, "MARKER", 1)
		db.ExpectQuery(regexp.QuoteMeta("SELECT EXISTS (SELECT 1 FROM raw_tdx.bus_route WHERE city = $1 LIMIT 1)")).
			WithArgs("Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"exists"}).AddRow(true))
		db.ExpectExec(_stateTouchPattern).
			WithArgs("bus_route", "city", "Taipei", "cycle-test").
			WillReturnResult(pgxmock.NewResult("UPDATE", 0))
		db.ExpectRollback()

		err := raw.VerifyAndTouchLandingWithDB(
			context.Background(), db, raw.Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER", "cycle-test",
		)
		assertLandingMismatch(t, err, "state_update")
	})
}

func assertLandingMismatch(t *testing.T, err error, reason string) {
	t.Helper()
	if !errors.Is(err, raw.ErrLandingStateMismatch) {
		t.Fatalf("error = %v, want raw.ErrLandingStateMismatch", err)
	}
	var mismatch *raw.LandingStateMismatchError
	if !errors.As(err, &mismatch) {
		t.Fatalf("error type = %T, want *raw.LandingStateMismatchError", err)
	}
	if mismatch.Reason != reason {
		t.Fatalf("mismatch reason = %q, want %q", mismatch.Reason, reason)
	}
}

func TestRawTDXSourceUsesLandingStateForFreshEmptyAndCountIntegrity(t *testing.T) {
	readOptions := pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}
	t.Run("verified empty is fresh", func(t *testing.T) {
		db := newRawLandingMock(t)
		fresh := time.Now().UTC().Truncate(time.Microsecond)
		db.ExpectBeginTx(readOptions)
		db.ExpectQuery(_stateFreshnessPattern).
			WithArgs("bus_route", "city", "Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"fetched_at", "row_count"}).AddRow(fresh, int64(0)))
		db.ExpectQuery(`SELECT .* FROM raw_tdx\.bus_route t WHERE city = \$1`).
			WithArgs("Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"row"}))
		db.ExpectCommit()

		body, fetchedAt, err := (rawTDXSource{pool: db}).DatasetJSON(
			context.Background(), "bus_route", "city", "Taipei",
		)
		if err != nil {
			t.Fatalf("datasetJSON: %v", err)
		}
		if string(body) != "[]" || !fetchedAt.Equal(fresh) {
			t.Fatalf("body=%s fetchedAt=%s, want []/%s", body, fetchedAt, fresh)
		}
	})

	t.Run("missing state never consumes legacy raw rows", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectBeginTx(readOptions)
		db.ExpectQuery(_stateFreshnessPattern).
			WithArgs("bus_route", "city", "Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"fetched_at", "row_count"}))
		db.ExpectRollback()

		body, fetchedAt, err := (rawTDXSource{pool: db}).DatasetJSON(
			context.Background(), "bus_route", "city", "Taipei",
		)
		if err != nil || string(body) != "[]" || !fetchedAt.IsZero() {
			t.Fatalf("body=%s fetchedAt=%s err=%v, want []/zero/nil", body, fetchedAt, err)
		}
	})

	t.Run("exact count mismatch fails closed", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectBeginTx(readOptions)
		db.ExpectQuery(_stateFreshnessPattern).
			WithArgs("bus_route", "city", "Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"fetched_at", "row_count"}).AddRow(time.Now(), int64(2)))
		db.ExpectQuery(`SELECT .* FROM raw_tdx\.bus_route t WHERE city = \$1`).
			WithArgs("Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"row"}).AddRow([]byte(`{"routeuid":"R1"}`)))
		db.ExpectRollback()

		_, _, err := (rawTDXSource{pool: db}).DatasetJSON(
			context.Background(), "bus_route", "city", "Taipei",
		)
		assertLandingMismatch(t, err, "loader_row_count")
	})
}

func TestRawTDXSourceReturnsLandingCycleFromSameReadTransaction(t *testing.T) {
	readOptions := pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}
	db := newRawLandingMock(t)
	fresh := time.Now().UTC().Truncate(time.Microsecond)
	db.ExpectBeginTx(readOptions)
	db.ExpectQuery(`SELECT fetched_at, row_count, COALESCE\(landing_cycle, ''\) FROM raw_tdx\.landing_state`).
		WithArgs("bus_route", "city", "Taipei").
		WillReturnRows(pgxmock.NewRows([]string{"fetched_at", "row_count", "landing_cycle"}).AddRow(fresh, int64(0), "cycle-shared"))
	db.ExpectQuery(`SELECT .* FROM raw_tdx\.bus_route t WHERE city = \$1`).
		WithArgs("Taipei").
		WillReturnRows(pgxmock.NewRows([]string{"row"}))
	db.ExpectCommit()

	body, fetchedAt, cycle, err := (rawTDXSource{pool: db}).DatasetJSONWithLandingCycle(
		context.Background(), "bus_route", "city", "Taipei",
	)
	if err != nil {
		t.Fatalf("DatasetJSONWithLandingCycle: %v", err)
	}
	if string(body) != "[]" || !fetchedAt.Equal(fresh) || cycle != "cycle-shared" {
		t.Fatalf("body/fetched/cycle = %s/%s/%q, want []/%s/cycle-shared", body, fetchedAt, cycle, fresh)
	}
}

func TestReportStalePartitions(t *testing.T) {
	const scanPattern = `SELECT table_name, partition_value, fetched_at FROM raw_tdx\.landing_state WHERE fetched_at < \$1`

	t.Run("counts stale partitions", func(t *testing.T) {
		db := newRawLandingMock(t)
		old := time.Now().Add(-30 * 24 * time.Hour)
		db.ExpectQuery(scanPattern).
			WithArgs(pgxmock.AnyArg()).
			WillReturnRows(pgxmock.NewRows([]string{"table_name", "partition_value", "fetched_at"}).
				AddRow("bus_stationgroup", "Taoyuan", old).
				AddRow("bus_routefare", "Keelung", old))

		if got := raw.ReportStalePartitions(context.Background(), db); got != 2 {
			t.Fatalf("stale count = %d, want 2", got)
		}
	})

	t.Run("scan failure is not fatal", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectQuery(scanPattern).
			WithArgs(pgxmock.AnyArg()).
			WillReturnError(errors.New("database unavailable"))

		if got := raw.ReportStalePartitions(context.Background(), db); got != 0 {
			t.Fatalf("stale count = %d, want 0", got)
		}
	})
}

func newRawLandingMock(t *testing.T) pgxmock.PgxPoolIface {
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
