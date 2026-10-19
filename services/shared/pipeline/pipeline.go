package pipeline

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"reflect"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"go.uber.org/zap"
)

type CopyUpsertSink interface {
	CopyUpsert(ctx context.Context, spec CopyUpsertSpec, rows [][]any) error
}

// CopyUpsertStmt is one parameterized statement copyUpsert runs inside its
// transaction before staging, e.g. the partition DELETE the mrt_schedule
// partition-replace load performs before re-inserting a system's rows.
type CopyUpsertStmt struct {
	SQL  string
	Args []any
}

type CopyUpsertSpec struct {
	Key       string
	PreExec   []CopyUpsertStmt
	CreateSQL string
	TempTable string
	CopyCols  []string
	InsertSQL string
}

type LoadTx interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	CopyFrom(context.Context, pgx.Identifier, []string, pgx.CopyFromSource) (int64, error)
	Commit(context.Context) error
	Rollback(context.Context) error
}

type LoadTxBeginner interface {
	BeginLoadTx(context.Context) (LoadTx, error)
}

func DecodeLoadArray[T any](dec *json.Decoder, dataset string, validate func(int, T) error) ([]T, error) {
	if err := openLoadArray(dec, dataset); err != nil {
		return nil, err
	}

	items, err := readLoadItems(dec, dataset, validate)
	if err != nil {
		return nil, err
	}

	if err := finishLoadArray(dec, dataset); err != nil {
		return nil, err
	}
	return items, nil
}

func validateLoadItem[T any](index int, item T, validate func(int, T) error) error {
	if validate == nil {
		return nil
	}
	return validate(index, item)
}

func finishLoadArray(dec *json.Decoder, dataset string) error {
	tok, err := dec.Token()
	if err != nil {
		return _oops.With("dataset", dataset).Wrapf(err, "closing array")
	}
	if tok != json.Delim(']') {
		return _oops.With("dataset", dataset).With("token", tok).Errorf("closing array")
	}
	return rejectLoadTrailer(dec, dataset)
}

// AppendUniqueLoadRow keeps the first row for a target natural key. Identical
// source duplicates collapse deterministically; divergent duplicates abort the
// load before the sink opens a transaction.
func AppendUniqueLoadRow(rows *[][]any, seen map[string][]any, key, label string, row []any) error {
	if prior, ok := seen[key]; ok {
		if reflect.DeepEqual(prior, row) {
			return nil
		}
		return _oops.With("label", label).With("key", key).Errorf("divergent duplicate")
	}
	seen[key] = row
	*rows = append(*rows, row)
	return nil
}

func RunCopyUpsert(ctx context.Context, db LoadTxBeginner, spec CopyUpsertSpec, rows [][]any) (resultErr error) {
	b, err := beginCopyUpsert(ctx, db, spec.Key)
	if err != nil {
		return err
	}

	committed := false
	defer func() { resultErr = errors.Join(resultErr, rollbackUncommittedLoad(committed, b, spec.Key)) }()
	if err := completeCopyUpsert(ctx, b, spec, rows); err != nil {
		return err
	}

	committed = true
	zap.S().Infow("success",
		"component", "load",
		"action", "copy_upsert",
		"dataset", spec.Key,
		"event", "success",
		"rows", len(rows),
	)
	return nil
}

func rollbackLoad(tx LoadTx, key string) error {
	rollbackCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := errorWithout(tx.Rollback(rollbackCtx), pgx.ErrTxClosed); err != nil {
		return _oops.With("spec_key", key).Wrapf(err, "copy-upsert rollback")
	}
	return nil
}

func stageCopyUpsert(ctx context.Context, b LoadTx, spec CopyUpsertSpec, rows [][]any) error {
	if err := execCopyPreparation(ctx, b, spec); err != nil {
		return err
	}
	if err := copyUpsertRows(ctx, b, spec, rows); err != nil {
		return err
	}
	if _, err := b.Exec(ctx, spec.InsertSQL); err != nil {
		return _oops.With("spec_key", spec.Key).Wrapf(err, "copy-upsert final exec")
	}
	return nil
}

func Mask(mon, tues, wed, thur, fri, satur, sun bool, nationalHoliday ...bool) uint8 {
	var res uint8
	days := []bool{mon, tues, wed, thur, fri, satur, sun, firstHolidayFlag(nationalHoliday)}
	for i, v := range days {
		if v {
			res |= 1 << i
		}
	}
	return res
}

// Mask2 is Mask for TDX ServiceDay fields that arrive as uint8 flags (1 = runs).
// It packs Monday..Sunday into bits 0..6; unlike Mask it has no holiday bit.
func Mask2(mon, tues, wed, thur, fri, satur, sun uint8) uint8 {
	var res uint8
	days := []uint8{mon, tues, wed, thur, fri, satur, sun}
	for i, v := range days {
		if v == 1 {
			res |= 1 << i
		}
	}
	return res
}

// WithTimeout runs fn with a context that is canceled after d. It exists so cron
// jobs cannot run unbounded; fn is expected to honor ctx cancellation itself.
func WithTimeout(d time.Duration, fn func(context.Context)) {
	_ = RunWithTimeout(context.Background(), d, func(ctx context.Context) error {
		fn(ctx)
		return nil
	})
}

// RunWithTimeout bounds one cooperative job attempt. A job that returns nil
// only after its deadline is still reported as a deadline failure.
func RunWithTimeout(parent context.Context, d time.Duration, job func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(parent, d)
	defer cancel()
	err := job(ctx)
	if err == nil && ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

// RunDailyWithRetry is the testable retry core. Every failed daily attempt is
// transient by definition: the same bounded operation is safe to repeat and a
// later attempt must not be suppressed by a partition-level failure.
func RunDailyWithRetry(parent context.Context, d, backoff time.Duration, job func(context.Context) error) error {
	return obs.Retry(parent, 3, backoff, func() error {
		return obs.Transient(RunWithTimeout(parent, d, job))
	})
}

func errorWithout(err, target error) error {
	if err == nil {
		return nil
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		return joinedWithout(joined.Unwrap(), target)
	}
	return wrappedWithout(err, target)
}

func wrappedWithout(err, target error) error {
	if wrapped, ok := err.(interface{ Unwrap() error }); ok {
		child := wrapped.Unwrap()
		if errors.Is(child, target) {
			return errorWithout(child, target)
		}
	}
	if errors.Is(err, target) {
		return nil
	}
	return err
}

func joinedWithout(children []error, target error) error {
	remaining := make([]error, 0, len(children))
	for _, child := range children {
		if child = errorWithout(child, target); child != nil {
			remaining = append(remaining, child)
		}
	}
	return errors.Join(remaining...)
}

func openLoadArray(dec *json.Decoder, dataset string) error {
	tok, err := dec.Token()
	if err != nil {
		return _oops.With("dataset", dataset).Wrapf(err, "opening array")
	}
	if tok != json.Delim('[') {
		return _oops.With("dataset", dataset).With("token", tok).Errorf("opening array")
	}

	return nil
}

func readLoadItems[T any](dec *json.Decoder, dataset string, validate func(int, T) error) ([]T, error) {
	items := make([]T, 0)
	for index := 0; dec.More(); index++ {
		item, err := decodeLoadItem(dec, dataset, index, validate)
		if err != nil {
			return nil, err
		}

		items = append(items, item)
	}
	return items, nil
}

func decodeLoadItem[T any](dec *json.Decoder, dataset string, index int, validate func(int, T) error) (T, error) {
	var item T
	if err := dec.Decode(&item); err != nil {
		return item, _oops.With("dataset", dataset).With("index", index).Wrapf(err, "element decode")
	}
	if err := validateLoadItem(index, item, validate); err != nil {
		return item, _oops.With("dataset", dataset).With("index", index).Wrapf(err, "element")
	}
	return item, nil
}

func rejectLoadTrailer(dec *json.Decoder, dataset string) error {
	var trailing json.RawMessage
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return _oops.With("dataset", dataset).Errorf("trailing JSON value")
		}
		return _oops.With("dataset", dataset).Wrapf(err, "trailing JSON")
	}
	return nil
}

func beginCopyUpsert(ctx context.Context, db LoadTxBeginner, key string) (LoadTx, error) {
	if db == nil {
		return nil, _oops.With("spec_key", key).Errorf("copy-upsert begin: nil database")
	}
	b, err := db.BeginLoadTx(ctx)
	if err != nil {
		return nil, _oops.With("spec_key", key).Wrapf(err, "copy-upsert begin")
	}
	return b, nil
}

func rollbackUncommittedLoad(committed bool, tx LoadTx, key string) error {
	if committed {
		return nil
	}
	return rollbackLoad(tx, key)
}

func completeCopyUpsert(ctx context.Context, b LoadTx, spec CopyUpsertSpec, rows [][]any) error {
	if err := stageCopyUpsert(ctx, b, spec, rows); err != nil {
		return err
	}
	if err := b.Commit(ctx); err != nil {
		return _oops.With("spec_key", spec.Key).Wrapf(err, "copy-upsert commit")
	}
	return nil
}

func execCopyPreparation(ctx context.Context, b LoadTx, spec CopyUpsertSpec) error {
	for index, st := range spec.PreExec {
		if _, err := b.Exec(ctx, st.SQL, st.Args...); err != nil {
			return _oops.With("spec_key", spec.Key).With("index", index).Wrapf(err, "copy-upsert pre-exec")
		}
	}
	return nil
}

func copyUpsertRows(ctx context.Context, b LoadTx, spec CopyUpsertSpec, rows [][]any) error {
	if _, err := b.Exec(ctx, spec.CreateSQL); err != nil {
		return _oops.With("spec_key", spec.Key).Wrapf(err, "copy-upsert create temp")
	}
	if _, err := b.CopyFrom(ctx, pgx.Identifier{spec.TempTable}, spec.CopyCols, pgx.CopyFromRows(rows)); err != nil {
		return _oops.With("spec_key", spec.Key).With("temp_table", spec.TempTable).Wrapf(err, "copy-upsert COPY")
	}
	return nil
}

func firstHolidayFlag(flags []bool) bool {
	if len(flags) == 0 {
		return false
	}
	return flags[0]
}
