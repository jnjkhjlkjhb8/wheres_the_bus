package pipeline

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type faultLoadTxBeginner struct {
	tx       *faultLoadTx
	beginErr error
}

func (b *faultLoadTxBeginner) BeginLoadTx(context.Context) (LoadTx, error) {
	if b.beginErr != nil {
		return nil, b.beginErr
	}
	return b.tx, nil
}

type faultLoadTx struct {
	failAt              string
	failErr             error
	cancel              context.CancelFunc
	rolledBack          bool
	rollbackContextLive bool
	rollbackHasDeadline bool
	rollbackDeadline    time.Time
	rollbackErr         error
	stages              []string
	copyTable           pgx.Identifier
	copyCols            []string
	copyRows            [][]any
}

func (t *faultLoadTx) fail(stage string) error {
	if t.failAt != stage {
		return nil
	}
	if t.cancel != nil {
		t.cancel()
	}
	return t.failErr
}

func (t *faultLoadTx) Exec(_ context.Context, sql string, _ ...any) (pgconn.CommandTag, error) {
	stage := sql
	t.stages = append(t.stages, stage)
	if err := t.fail(stage); err != nil {
		return pgconn.CommandTag{}, err
	}
	return pgconn.NewCommandTag("OK"), nil
}

func (t *faultLoadTx) CopyFrom(_ context.Context, table pgx.Identifier, columns []string, source pgx.CopyFromSource) (int64, error) {
	t.stages = append(t.stages, "COPY")
	t.copyTable, t.copyCols = table, columns
	for source.Next() {
		row, err := source.Values()
		if err != nil {
			return 0, err
		}
		t.copyRows = append(t.copyRows, row)
	}
	if err := t.fail("COPY"); err != nil {
		return 0, err
	}
	return 1, nil
}

func (t *faultLoadTx) Commit(context.Context) error {
	t.stages = append(t.stages, "COMMIT")
	return t.fail("COMMIT")
}

func TestRunCopyUpsertCommitsStagedRowsWithoutRollback(t *testing.T) {
	spec := CopyUpsertSpec{Key: "probe", PreExec: []CopyUpsertStmt{{SQL: "DELETE"}, {SQL: "CHECK"}}, CreateSQL: "CREATE", TempTable: "temporary", CopyCols: []string{"id", "name"}, InsertSQL: "INSERT"}
	rows := [][]any{{1, "first"}, {2, "second"}}
	tx := &faultLoadTx{}
	if err := RunCopyUpsert(context.Background(), &faultLoadTxBeginner{tx: tx}, spec, rows); err != nil {
		t.Fatal(err)
	}
	if tx.rolledBack || !reflect.DeepEqual(tx.stages, []string{"DELETE", "CHECK", "CREATE", "COPY", "INSERT", "COMMIT"}) {
		t.Fatalf("transaction stages=%v rollback=%v", tx.stages, tx.rolledBack)
	}
	if !reflect.DeepEqual(tx.copyTable, pgx.Identifier{"temporary"}) || !reflect.DeepEqual(tx.copyCols, spec.CopyCols) || !reflect.DeepEqual(tx.copyRows, rows) {
		t.Fatalf("COPY table=%v columns=%v rows=%v", tx.copyTable, tx.copyCols, tx.copyRows)
	}
	if err := RunCopyUpsert(context.Background(), nil, spec, rows); err == nil || !errMentions(err, "nil database") {
		t.Fatalf("nil database error=%v", err)
	}
}

func (t *faultLoadTx) Rollback(ctx context.Context) error {
	t.rolledBack = true
	t.rollbackContextLive = ctx.Err() == nil
	t.rollbackDeadline, t.rollbackHasDeadline = ctx.Deadline()
	return t.rollbackErr
}

func TestRunCopyUpsertWrapsEveryFailureStage(t *testing.T) {
	wantErr := errors.New("injected write failure")
	spec := CopyUpsertSpec{
		Key:       "probe",
		PreExec:   []CopyUpsertStmt{{SQL: "PRE"}},
		CreateSQL: "CREATE",
		TempTable: "temp_probe",
		CopyCols:  []string{"id"},
		InsertSQL: "INSERT",
	}
	tests := []struct {
		name      string
		failAt    string
		beginErr  bool
		wantStage string
	}{
		{"begin", "", true, "begin"},
		{"pre exec", "PRE", false, "pre-exec"},
		{"create temp", "CREATE", false, "create temp"},
		{"copy", "COPY", false, "COPY"},
		{"final exec", "INSERT", false, "final exec"},
		{"commit", "COMMIT", false, "commit"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tx := &faultLoadTx{failAt: tt.failAt, failErr: wantErr}
			beginner := &faultLoadTxBeginner{tx: tx}
			if tt.beginErr {
				beginner.beginErr = wantErr
			}
			err := RunCopyUpsert(context.Background(), beginner, spec, [][]any{{1}})
			if !errors.Is(err, wantErr) || !errMentions(err, "probe") || !errMentions(err, tt.wantStage) {
				t.Fatalf("RunCopyUpsert error = %v, want wrapped probe/%s error", err, tt.wantStage)
			}
			if !tt.beginErr && !tx.rolledBack {
				t.Fatal("started transaction was not rolled back")
			}
		})
	}
}

func TestRunCopyUpsertCanceledFailureUsesBoundedLiveRollback(t *testing.T) {
	wantErr := errors.New("late insert failure")
	ctx, cancel := context.WithCancel(context.Background())
	tx := &faultLoadTx{failAt: "INSERT", failErr: wantErr, cancel: cancel}
	spec := CopyUpsertSpec{
		Key: "probe", CreateSQL: "CREATE", TempTable: "temp_probe",
		CopyCols: []string{"id"}, InsertSQL: "INSERT",
	}
	err := RunCopyUpsert(ctx, &faultLoadTxBeginner{tx: tx}, spec, [][]any{{1}})
	if !errors.Is(err, wantErr) {
		t.Fatalf("RunCopyUpsert error = %v, want %v", err, wantErr)
	}
	if !tx.rolledBack || !tx.rollbackContextLive || !tx.rollbackHasDeadline {
		t.Fatalf("rollback = %v live=%v bounded=%v, want true/true/true", tx.rolledBack, tx.rollbackContextLive, tx.rollbackHasDeadline)
	}
	remaining := time.Until(tx.rollbackDeadline)
	if remaining <= 0 || remaining > 5*time.Second {
		t.Fatalf("rollback deadline remaining = %s, want (0,5s]", remaining)
	}
	if _, ok := ctx.Deadline(); ok {
		t.Fatal("test caller context unexpectedly had a deadline; rollback deadline was not independent")
	}
}

func TestRunCopyUpsertJoinsCommitAndRollbackFailures(t *testing.T) {
	commitErr := errors.New("commit outcome failed")
	rollbackErr := errors.New("rollback transport failed")
	tx := &faultLoadTx{failAt: "COMMIT", failErr: commitErr, rollbackErr: rollbackErr}
	spec := CopyUpsertSpec{
		Key: "probe", CreateSQL: "CREATE", TempTable: "temp_probe",
		CopyCols: []string{"id"}, InsertSQL: "INSERT",
	}
	err := RunCopyUpsert(context.Background(), &faultLoadTxBeginner{tx: tx}, spec, [][]any{{1}})
	if !errors.Is(err, commitErr) || !errors.Is(err, rollbackErr) {
		t.Fatalf("RunCopyUpsert error = %v, want joined commit and rollback failures", err)
	}
	if !errMentions(err, "commit") || !errMentions(err, "rollback") {
		t.Fatalf("RunCopyUpsert error = %v, want wrapped commit and rollback stages", err)
	}
}

func TestRunCopyUpsertCommitFailureIgnoresClosedTransactionRollback(t *testing.T) {
	commitErr := errors.New("commit outcome failed")
	tx := &faultLoadTx{failAt: "COMMIT", failErr: commitErr, rollbackErr: pgx.ErrTxClosed}
	spec := CopyUpsertSpec{
		Key: "probe", CreateSQL: "CREATE", TempTable: "temp_probe",
		CopyCols: []string{"id"}, InsertSQL: "INSERT",
	}
	err := RunCopyUpsert(context.Background(), &faultLoadTxBeginner{tx: tx}, spec, [][]any{{1}})
	if !errors.Is(err, commitErr) {
		t.Fatalf("RunCopyUpsert error = %v, want primary commit failure", err)
	}
	if errors.Is(err, pgx.ErrTxClosed) || errMentions(err, "rollback") {
		t.Fatalf("RunCopyUpsert error = %v, closed transaction rollback must not mask the commit outcome", err)
	}
}

func TestRunCopyUpsertDoesNotHideRollbackFailureJoinedWithErrTxClosed(t *testing.T) {
	commitErr := errors.New("commit outcome failed")
	rollbackErr := errors.New("rollback transport failed")
	tx := &faultLoadTx{
		failAt:      "COMMIT",
		failErr:     commitErr,
		rollbackErr: errors.Join(pgx.ErrTxClosed, rollbackErr),
	}
	spec := CopyUpsertSpec{
		Key: "probe", CreateSQL: "CREATE", TempTable: "temp_probe",
		CopyCols: []string{"id"}, InsertSQL: "INSERT",
	}
	err := RunCopyUpsert(context.Background(), &faultLoadTxBeginner{tx: tx}, spec, [][]any{{1}})
	if !errors.Is(err, commitErr) || !errors.Is(err, rollbackErr) {
		t.Fatalf("RunCopyUpsert error = %v, want primary commit and non-sentinel rollback failures", err)
	}
}
