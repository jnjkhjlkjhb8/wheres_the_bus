package raw

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	pgxmock "github.com/pashagolub/pgxmock/v4"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestRawContractURLCityBoundaryPreservesTarget(t *testing.T) {
	for _, tt := range []struct{ url, city string }{
		{url: "/v2/Bus/Route/City", city: ""},
		{url: "/v2/Bus/Route/City/Taipei", city: "Taipei"},
	} {
		t.Run(tt.url, func(t *testing.T) {
			target, ok := DumpTarget(tt.url)
			want := Target{Table: "bus_route", PartCol: "city", PartVal: tt.city}
			if !ok || target != want {
				t.Fatalf("raw URL target = %+v, %v, want %+v", target, ok, want)
			}
		})
	}
}

func rawContractLogCause(entry observer.LoggedEntry) error {
	for _, field := range entry.Context {
		if field.Key == "err" {
			err, _ := field.Interface.(error)
			return err
		}
	}
	return nil
}

func TestRawContractArchiveFailureKeepsPayloadAndReportsOriginalCause(t *testing.T) {
	core, observed := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	want := errors.New("archive host unavailable")
	db := &fakeExecer{err: want}
	reader := bytes.NewReader([]byte(`[{"RouteUID":"R1"}]`))
	ArchivePayload(t.Context(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "marker", "cycle", reader)
	failures := observed.FilterMessage("insert error").All()
	if len(failures) != 1 || !errors.Is(rawContractLogCause(failures[0]), want) {
		t.Fatalf("archive failure diagnostics = %#v, want original cause", failures)
	}
	if len(observed.FilterMessage("archived payload").All()) != 0 {
		t.Fatal("failed archive reported success")
	}
	if len(db.args) != 1 || gunzip(t, db.args[0][5].([]byte)) != `[{"RouteUID":"R1"}]` {
		t.Fatalf("archive attempted payload = %#v", db.args)
	}
	body, err := io.ReadAll(reader)
	if err != nil || string(body) != `[{"RouteUID":"R1"}]` {
		t.Fatalf("body after archive failure = %q, %v", body, err)
	}
}

type rawContractCutoff struct{ value time.Time }

func (c *rawContractCutoff) Match(value any) bool {
	cutoff, ok := value.(time.Time)
	if ok {
		c.value = cutoff
	}
	return ok
}

func TestRawContractStaleSweepUsesSevenDayCutoffAndReportsPartitions(t *testing.T) {
	core, observed := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	db := newRawLandingMock(t)
	cutoff := &rawContractCutoff{}
	old := time.Now().Add(-8 * 24 * time.Hour)
	db.ExpectQuery(`SELECT table_name, partition_value, fetched_at FROM raw_tdx\.landing_state WHERE fetched_at < \$1`).
		WithArgs(cutoff).
		WillReturnRows(pgxmock.NewRows([]string{"table_name", "partition_value", "fetched_at"}).
			AddRow("bus_route", "Taipei", old).
			AddRow("bus_station", "Keelung", old))
	before := time.Now().Add(-7 * 24 * time.Hour)
	count := ReportStalePartitions(t.Context(), db)
	after := time.Now().Add(-7 * 24 * time.Hour)
	if count != 2 || cutoff.value.Before(before) || cutoff.value.After(after) {
		t.Fatalf("stale count = %d, cutoff %v outside [%v, %v]", count, cutoff.value, before, after)
	}
	partitions := observed.FilterField(zap.String("event", "stale_partition")).All()
	summaries := observed.FilterField(zap.String("event", "stale_summary")).All()
	if len(partitions) != 2 || len(summaries) != 1 || summaries[0].ContextMap()["count"] != int64(2) {
		t.Fatalf("stale sweep diagnostics: partitions %#v, summaries %#v", partitions, summaries)
	}
	if len(observed.FilterField(zap.String("event", "stale_scan_error")).All()) != 0 {
		t.Fatal("successful stale sweep reported a scan error")
	}
	if partitions[0].ContextMap()["table"] != "bus_route" || partitions[0].ContextMap()["partition"] != "Taipei" || partitions[1].ContextMap()["table"] != "bus_station" || partitions[1].ContextMap()["partition"] != "Keelung" {
		t.Fatalf("stale sweep lost partition identity: %#v", partitions)
	}
}

func TestRawContractEmptyStaleSweepEmitsNoFailureOrStaleSummary(t *testing.T) {
	core, observed := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	db := newRawLandingMock(t)
	db.ExpectQuery(`SELECT table_name, partition_value, fetched_at`).WithArgs(pgxmock.AnyArg()).
		WillReturnRows(pgxmock.NewRows([]string{"table_name", "partition_value", "fetched_at"}))
	if count := ReportStalePartitions(t.Context(), db); count != 0 {
		t.Fatalf("empty stale count = %d", count)
	}
	for _, event := range []string{"stale_scan_error", "stale_partition", "stale_summary"} {
		if len(observed.FilterField(zap.String("event", event)).All()) != 0 {
			t.Fatalf("empty successful scan emitted %s", event)
		}
	}
}

func TestRawContractStaleIterationFailureReportsCauseWithoutSuccessSummary(t *testing.T) {
	core, observed := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	db := newRawLandingMock(t)
	want := errors.New("stale partition stream interrupted")
	db.ExpectQuery(`SELECT table_name, partition_value, fetched_at`).WithArgs(pgxmock.AnyArg()).
		WillReturnRows(pgxmock.NewRows([]string{"table_name", "partition_value", "fetched_at"}).
			AddRow("bus_route", "Taipei", time.Now().Add(-8*24*time.Hour)).
			AddRow("bus_station", "Keelung", time.Now().Add(-8*24*time.Hour)).RowError(1, want))
	if count := ReportStalePartitions(t.Context(), db); count != 1 {
		t.Fatalf("partial stale count = %d, want one completed row", count)
	}
	failures := observed.FilterField(zap.String("event", "stale_scan_error")).All()
	if len(failures) != 1 || !errors.Is(rawContractLogCause(failures[0]), want) {
		t.Fatalf("stale iteration diagnostics = %#v, want original cause", failures)
	}
	if len(observed.FilterField(zap.String("event", "stale_summary")).All()) != 0 {
		t.Fatal("partial failed scan emitted successful summary")
	}
}

func TestRawContractDumpRejectsInvalidTargetBeforeMarkerOrTransaction(t *testing.T) {
	db := newRawLandingMock(t)
	err := DumpWithDB(t.Context(), db, Target{Table: "not_a_raw_table", PartCol: "city", PartVal: "Taipei"}, "", "cycle", []byte(`[]`))
	if !errors.Is(err, errRawDump) || !strings.Contains(err.Error(), "table not whitelisted") {
		t.Fatalf("invalid target error = %v, want whitelist failure before marker validation", err)
	}
}

func TestRawContractExactChunkBoundaryWritesEachRowOnceWithoutEmptyBatch(t *testing.T) {
	const batchBytes = 4 << 20
	const prefix = `{"RouteUID":"R1","Pad":"`
	const suffix = `"}`
	large := prefix + strings.Repeat("x", batchBytes-1-len(prefix)-len(suffix)) + suffix
	for _, tt := range []struct {
		name, body string
		chunks     [][]byte
		rows       int64
	}{
		{name: "exact full batch", body: "[" + large + "]", chunks: [][]byte{[]byte("[" + large + "]")}, rows: 1},
		{name: "full batch then another row", body: "[" + large + `,{"RouteUID":"R2"}]`, chunks: [][]byte{[]byte("[" + large + "]"), []byte(`[{"RouteUID":"R2"}]`)}, rows: 2},
	} {
		t.Run(tt.name, func(t *testing.T) {
			db := newRawLandingMock(t)
			db.ExpectBegin()
			db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).WillReturnResult(pgxmock.NewResult("SET", 0))
			db.ExpectExec(`DELETE FROM raw_tdx.bus_route WHERE city = \$1`).WithArgs("Taipei").WillReturnResult(pgxmock.NewResult("DELETE", 3))
			for _, chunk := range tt.chunks {
				db.ExpectExec(`INSERT INTO raw_tdx.bus_route`).WithArgs(`{"city":"Taipei"}`, chunk).WillReturnResult(pgxmock.NewResult("INSERT", 1))
			}
			db.ExpectExec(_stateUpsertPattern).WithArgs("bus_route", "city", "Taipei", "marker", tt.rows, "cycle").WillReturnResult(pgxmock.NewResult("INSERT", 1))
			db.ExpectCommit()
			if err := DumpWithDB(t.Context(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "marker", "cycle", []byte(tt.body)); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRawContractMalformedTrailingPayloadKeepsParserCauseAndRollsBack(t *testing.T) {
	db := newRawLandingMock(t)
	db.ExpectBegin()
	db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).WillReturnResult(pgxmock.NewResult("SET", 0))
	db.ExpectExec(`DELETE FROM raw_tdx.bus_route WHERE city = \$1`).WithArgs("Taipei").WillReturnResult(pgxmock.NewResult("DELETE", 3))
	db.ExpectRollback()
	err := landRawTDXWithDB(t.Context(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "marker", "cycle", strings.NewReader(`[{"RouteUID":"R1"}] invalid`))
	var syntaxError *json.SyntaxError
	if !errors.As(err, &syntaxError) {
		t.Fatalf("malformed trailing payload error = %v, want JSON syntax cause", err)
	}
}

type rawContractRollback struct {
	called, hasDeadline bool
	err                 error
	remaining           time.Duration
}

type rawContractCancellingTx struct {
	pgx.Tx
	cancel   context.CancelFunc
	rollback *rawContractRollback
}

func (tx rawContractCancellingTx) Exec(ctx context.Context, query string, args ...any) (pgconn.CommandTag, error) {
	tag, err := tx.Tx.Exec(ctx, query, args...)
	if err != nil {
		tx.cancel()
	}
	return tag, err
}

func (tx rawContractCancellingTx) Rollback(ctx context.Context) error {
	tx.rollback.called = true
	tx.rollback.err = ctx.Err()
	deadline, ok := ctx.Deadline()
	tx.rollback.hasDeadline = ok
	tx.rollback.remaining = time.Until(deadline)
	return tx.Tx.Rollback(ctx)
}

type rawContractCancellingBeginner struct {
	LandingBeginner
	cancel   context.CancelFunc
	rollback *rawContractRollback
}

func (db rawContractCancellingBeginner) Begin(ctx context.Context) (pgx.Tx, error) {
	tx, err := db.LandingBeginner.Begin(ctx)
	if err != nil {
		return nil, err
	}
	return rawContractCancellingTx{Tx: tx, cancel: db.cancel, rollback: db.rollback}, nil
}

func TestRawContractCancellationLeavesRollbackContextUsable(t *testing.T) {
	for _, entry := range []string{"dump", "verified 304"} {
		t.Run(entry, func(t *testing.T) {
			db := newRawLandingMock(t)
			want := errors.New("landing lock failed during request cancellation")
			db.ExpectBegin()
			db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")).WillReturnError(want)
			db.ExpectRollback()
			ctx, cancel := context.WithCancel(t.Context())
			t.Cleanup(cancel)
			rollback := &rawContractRollback{}
			beginner := rawContractCancellingBeginner{LandingBeginner: db, cancel: cancel, rollback: rollback}
			target := Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}
			var err error
			if entry == "dump" {
				err = DumpWithDB(ctx, beginner, target, "marker", "cycle", []byte(`[]`))
			} else {
				err = VerifyAndTouchLandingWithDB(ctx, beginner, target, "marker", "cycle")
			}
			wantError := want
			if entry == "dump" {
				wantError = context.Canceled
			}
			if !errors.Is(err, wantError) || !errors.Is(ctx.Err(), context.Canceled) {
				t.Fatalf("landing error = %v, request context = %v, want %v and canceled request", err, ctx.Err(), wantError)
			}
			if !rollback.called || rollback.err != nil || !rollback.hasDeadline || rollback.remaining <= 0 {
				t.Fatalf("rollback context = %+v, want active bounded cleanup after request cancellation", rollback)
			}
		})
	}
}
