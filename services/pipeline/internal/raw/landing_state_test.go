package raw

import (
	"bytes"
	"context"
	"errors"
	"regexp"
	"testing"

	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestLandRawTDXCommitsRowsAndStateAtomically(t *testing.T) {
	db := newRawLandingMock(t)
	db.ExpectBegin()
	db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
		WillReturnResult(pgxmock.NewResult("SET", 0))
	db.ExpectExec(regexp.QuoteMeta(rawDeleteSQL(Target{Table: "bus_route", PartCol: "city"}))).
		WithArgs("Taipei").
		WillReturnResult(pgxmock.NewResult("DELETE", 3))
	db.ExpectExec(regexp.QuoteMeta(rawInsertSQL("bus_route"))).
		WithArgs(`{"city":"Taipei"}`, []byte("[]")).
		WillReturnResult(pgxmock.NewResult("INSERT", 0))
	db.ExpectExec(_stateUpsertPattern).
		WithArgs("bus_route", "city", "Taipei", "MARKER-EMPTY", int64(0), "cycle-test").
		WillReturnResult(pgxmock.NewResult("INSERT", 1))
	db.ExpectCommit()

	err := landRawTDXWithDB(
		context.Background(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER-EMPTY", "cycle-test", bytes.NewBufferString("[]"),
	)
	if err != nil {
		t.Fatalf("landRawTDXWithDB: %v", err)
	}
}

func TestLandRawTDXRollsBackWhenStateUpsertFails(t *testing.T) {
	db := newRawLandingMock(t)
	stateErr := errors.New("state write failed")
	db.ExpectBegin()
	db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
		WillReturnResult(pgxmock.NewResult("SET", 0))
	db.ExpectExec(regexp.QuoteMeta(rawDeleteSQL(Target{Table: "bus_route", PartCol: "city"}))).
		WithArgs("Taipei").
		WillReturnResult(pgxmock.NewResult("DELETE", 1))
	db.ExpectExec(regexp.QuoteMeta(rawInsertSQL("bus_route"))).
		WithArgs(`{"city":"Taipei"}`, []byte("[]")).
		WillReturnResult(pgxmock.NewResult("INSERT", 0))
	db.ExpectExec(_stateUpsertPattern).
		WithArgs("bus_route", "city", "Taipei", "MARKER", int64(0), "cycle-test").
		WillReturnError(stateErr)
	db.ExpectRollback()

	err := landRawTDXWithDB(
		context.Background(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER", "cycle-test", bytes.NewBufferString("[]"),
	)
	if !errors.Is(err, stateErr) {
		t.Fatalf("land error = %v, want %v", err, stateErr)
	}
}

func TestRawLandingPersistsSharedCycleForFullAndVerified304(t *testing.T) {
	t.Run("full verified empty landing", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectBegin()
		db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
			WillReturnResult(pgxmock.NewResult("SET", 0))
		db.ExpectExec(regexp.QuoteMeta(rawDeleteSQL(Target{Table: "bus_route", PartCol: "city"}))).
			WithArgs("Taipei").
			WillReturnResult(pgxmock.NewResult("DELETE", 3))
		db.ExpectExec(regexp.QuoteMeta(rawInsertSQL("bus_route"))).
			WithArgs(`{"city":"Taipei"}`, []byte("[]")).
			WillReturnResult(pgxmock.NewResult("INSERT", 0))
		db.ExpectExec(`INSERT INTO raw_tdx\.landing_state .*landing_cycle.*ON CONFLICT.*landing_cycle=EXCLUDED\.landing_cycle`).
			WithArgs("bus_route", "city", "Taipei", "MARKER-EMPTY", int64(0), "cycle-shared").
			WillReturnResult(pgxmock.NewResult("INSERT", 1))
		db.ExpectCommit()

		err := landRawTDXWithDB(
			context.Background(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER-EMPTY", "cycle-shared", bytes.NewBufferString("[]"),
		)
		if err != nil {
			t.Fatalf("landRawTDXWithDB: %v", err)
		}
	})

	t.Run("verified 304", func(t *testing.T) {
		db := newRawLandingMock(t)
		db.ExpectBegin()
		db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).
			WillReturnResult(pgxmock.NewResult("SET", 0))
		expectStateRead(db, "MARKER", 0)
		db.ExpectQuery(regexp.QuoteMeta("SELECT EXISTS (SELECT 1 FROM raw_tdx.bus_route WHERE city = $1 LIMIT 1)")).
			WithArgs("Taipei").
			WillReturnRows(pgxmock.NewRows([]string{"exists"}).AddRow(false))
		db.ExpectExec(`UPDATE raw_tdx\.landing_state SET fetched_at=now\(\), landing_cycle=\$4 WHERE table_name=\$1 AND partition_column=\$2 AND partition_value=\$3`).
			WithArgs("bus_route", "city", "Taipei", "cycle-shared").
			WillReturnResult(pgxmock.NewResult("UPDATE", 1))
		db.ExpectCommit()

		if err := VerifyAndTouchLandingWithDB(
			context.Background(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER", "cycle-shared",
		); err != nil {
			t.Fatalf("verifyAndTouchRawLandingWithDB: %v", err)
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
