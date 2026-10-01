package history

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
)

// fakeExecer records every statement Insert issues so a test can assert
// how a row set was split across INSERTs.
type fakeExecer struct {
	stmts []string
	args  [][]any
	err   error
}

func (f *fakeExecer) ExecContext(_ context.Context, q string, a ...any) (sql.Result, error) {
	f.stmts = append(f.stmts, q)
	f.args = append(f.args, a)
	return nil, f.err
}

// With no database configured the rebuild must not run: writing from zero
// segments would look like a successful rebuild that found nothing.
func TestComputeSegmentTimesSkipsWithoutDB(t *testing.T) {
	if err := ComputeSegmentTimesFromEstimates(context.Background(), nil, fixtureHistory{}); err != nil {
		t.Errorf("want a silent skip, got %v", err)
	}
}

func TestSegmentRebuildsSkipWithoutHistory(t *testing.T) {
	if err := ComputeSegmentTimesFromEstimates(context.Background(), nil, nil); err != nil {
		t.Errorf("ComputeSegmentTimesFromEstimates: want a silent skip, got %v", err)
	}
}

func TestFillPredictionActualsSkipsWithoutHistory(t *testing.T) {
	n, err := fillPredictionActuals(context.Background(), nil, nil)
	if err != nil || n != 0 {
		t.Errorf("fillPredictionActuals = (%d, %v), want (0, nil)", n, err)
	}
}

func TestArchiveInsertSQL(t *testing.T) {
	got := archiveInsertSQL("bike_availability_history", []string{"a", "b"}, 3)
	want := "INSERT IGNORE INTO bike_availability_history (a,b) VALUES (?,?),(?,?),(?,?)"
	if got != want {
		t.Errorf("archiveInsertSQL:\n got %q\nwant %q", got, want)
	}
}

// Insert must split at archiveRowsPerInsert: MySQL rejects a statement
// past 65535 placeholders, so an unsplit day of ~200k rows would fail outright.
func TestArchiveInsertSplitsBatches(t *testing.T) {
	cols := []string{"a", "b"}
	rows := make([][]any, 2500)
	for i := range rows {
		rows[i] = []any{i, i * 2}
	}
	f := &fakeExecer{}
	if err := Insert(context.Background(), f, "t", cols, rows); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	wantRows := []int{RowsPerInsert, RowsPerInsert, 2500 - 2*RowsPerInsert}
	if len(f.stmts) != len(wantRows) {
		t.Fatalf("statements = %d, want %d", len(f.stmts), len(wantRows))
	}
	for i, n := range wantRows {
		if got := strings.Count(f.stmts[i], "(?,?)"); got != n {
			t.Errorf("statement %d has %d row groups, want %d", i, got, n)
		}
		if got := len(f.args[i]); got != n*len(cols) {
			t.Errorf("statement %d has %d args, want %d", i, got, n*len(cols))
		}
	}
	// Every row must appear exactly once across the batches, in order.
	var flat []any
	for _, a := range f.args {
		flat = append(flat, a...)
	}
	if len(flat) != 5000 {
		t.Fatalf("total args = %d, want 5000", len(flat))
	}
	if flat[0] != 0 || flat[4998] != 2499 {
		t.Errorf("row order lost: first=%v last-pair-head=%v", flat[0], flat[4998])
	}
}

func TestArchiveInsertNoopWhenDisabled(t *testing.T) {
	if err := Insert(context.Background(), nil, "t", []string{"a"}, [][]any{{1}}); err != nil {
		t.Errorf("nil archive should be a no-op, got %v", err)
	}
	f := &fakeExecer{}
	if err := Insert(context.Background(), f, "t", []string{"a"}, nil); err != nil {
		t.Errorf("empty rows should be a no-op, got %v", err)
	}
	if len(f.stmts) != 0 {
		t.Errorf("empty rows issued %d statements, want 0", len(f.stmts))
	}
}

// A row whose width does not match cols would silently shift every later value
// into the wrong column, so it must fail loudly instead.
func TestArchiveInsertRejectsRowWidthMismatch(t *testing.T) {
	f := &fakeExecer{}
	err := Insert(context.Background(), f, "t", []string{"a", "b"}, [][]any{{1, 2}, {3}})
	if err == nil {
		t.Fatal("want error on short row, got nil")
	}
	if !errMentions(err, "cols 2") {
		t.Errorf("error should name the expected width, got %v", err)
	}
}

func TestArchiveInsertWrapsExecError(t *testing.T) {
	sentinel := errors.New("boom")
	f := &fakeExecer{err: sentinel}
	err := Insert(context.Background(), f, "t", []string{"a"}, [][]any{{1}})
	if !errors.Is(err, sentinel) {
		t.Errorf("error = %v, want it to wrap %v", err, sentinel)
	}
}

// MySQL DATETIME carries no zone, so timestamps must leave Go already in UTC
// rather than relying on the driver's loc setting.
func TestArchiveUTC(t *testing.T) {
	local := time.Date(2026, 7, 30, 8, 0, 0, 0, pipeline.Taipei)
	got := archiveUTC([]any{"x", local, nil, int32(3)})
	ts, ok := got[1].(time.Time)
	if !ok {
		t.Fatalf("value 1 = %T, want time.Time", got[1])
	}
	if ts.Location() != time.UTC {
		t.Errorf("location = %v, want UTC", ts.Location())
	}
	if !ts.Equal(local) {
		t.Errorf("instant changed: %s != %s", ts, local)
	}
	if got[0] != "x" || got[2] != nil || got[3] != int32(3) {
		t.Errorf("non-time values altered: %v", got)
	}
}

// A batch must never exceed MySQL's placeholder cap; the column count is the
// half of that product most likely to drift.
func TestBusEtaHistoryColsFitPlaceholderCeiling(t *testing.T) {
	if n := len(_busEtaHistoryCols); n != 20 {
		t.Errorf("bus_eta_history insert columns = %d, want 20", n)
	}
	if got := RowsPerInsert * len(_busEtaHistoryCols); got > 65535 {
		t.Errorf("batch would bind %d placeholders, over MySQL's 65535 cap", got)
	}
}

// Insert must normalize timestamps itself: a caller that forgets would
// otherwise write local-clock values into a zone-less DATETIME column.
func TestArchiveInsertNormalizesTimestamps(t *testing.T) {
	local := time.Date(2026, 7, 30, 8, 0, 0, 0, pipeline.Taipei)
	f := &fakeExecer{}
	if err := Insert(context.Background(), f, "t", []string{"a"}, [][]any{{local}}); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	ts, ok := f.args[0][0].(time.Time)
	if !ok {
		t.Fatalf("arg = %T, want time.Time", f.args[0][0])
	}
	if ts.Location() != time.UTC {
		t.Errorf("location = %v, want UTC", ts.Location())
	}
}
