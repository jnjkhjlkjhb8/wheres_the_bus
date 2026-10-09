package raw

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"go.uber.org/zap"
)

var DB *pgxpool.Pool

// DumpEnabled gates the raw_tdx landing to ROLE=ingestor only, so the default
// prod transform path never writes raw_tdx.
var DumpEnabled bool

// IMSCacheKey is the If-Modified-Since cache key for a fetch target. The ingestor
// writes namespaced shared:raw:* keys; the default prod path keeps its legacy key
// so prod behavior is unchanged. Both key forms live in shared/keys.go.
func IMSCacheKey(name string) string {
	if DumpEnabled {
		return shared.TDXRawIMSKey(name)
	}
	return shared.TDXLegacyIMSKey(name)
}

func dbSince(name string) string {
	if DB == nil {
		return ""
	}
	var q string
	var arg any
	switch {
	case strings.HasPrefix(name, "tra_traindate_"):
		q = "SELECT MAX(updated_at) FROM tra_timetable WHERE train_date=$1"
		arg = strings.TrimPrefix(name, "tra_traindate_")
	case strings.HasPrefix(name, "thsr_traindate_"):
		q = "SELECT MAX(updated_at) FROM thsr_timetable WHERE train_date=$1"
		arg = strings.TrimPrefix(name, "thsr_traindate_")
	case name == "tra_stations":
		q = "SELECT MAX(updated_at) FROM tra_stations"
	case name == "thsr_stations":
		q = "SELECT MAX(updated_at) FROM thsr_stations"
	case name == "tra_fare":
		q = "SELECT MAX(updated_at) FROM tra_fares"
	case name == "thsr_fare":
		q = "SELECT MAX(updated_at) FROM thsr_fares"
	case strings.HasPrefix(name, "mrt_stations"):
		q = "SELECT MAX(updated_at) FROM mrt_station WHERE system=$1"
		arg = strings.TrimPrefix(name, "mrt_stations")
	case strings.HasPrefix(name, "mrt_firstlast"):
		q = "SELECT MAX(updated_at) FROM mrt_schedule WHERE system=$1"
		arg = strings.TrimPrefix(name, "mrt_firstlast")
	case strings.HasPrefix(name, "bike_stations"):
		q = "SELECT MAX(updated_at) FROM bike_stations WHERE city=$1"
		arg = strings.TrimPrefix(name, "bike_stations")
	default:
	}
	ctx := context.Background()
	var t *time.Time
	var err error
	if arg != nil {
		err = DB.QueryRow(ctx, q, arg).Scan(&t)
	} else {
		err = DB.QueryRow(ctx, q).Scan(&t)
	}
	if err != nil || t == nil {
		return ""
	}
	return t.UTC().Format(http.TimeFormat)
}

// dbSinceFallbackAllowed reports whether an empty IMS cache may fall back to a
// prod table's updated_at. Never in ingestor mode: a 304 against an empty
// raw_tdx would strand the landing table permanently empty.
func SinceFallbackAllowed() bool { return !DumpEnabled }

func SinceFallback(name string) string {
	if SinceFallbackAllowed() {
		return dbSince(name)
	}
	return ""
}

func DumpTarget(url string) (Target, bool) {
	var partVal string
	seg := strings.Split(strings.Trim(url, "/"), "/")
	if len(seg) < 3 || seg[0] != "v2" {
		return Target{}, false
	}
	cityOf := func() string {
		for i, s := range seg {
			if s == "City" && i+1 < len(seg) {
				return seg[i+1]
			}
			if s == "InterCity" {
				return "InterCity"
			}
		}
		return ""
	}
	var key dataset.FamSeg
	switch {
	case seg[1] == "Bus":
		key, partVal = dataset.FamSeg{Family: dataset.FamilyBusCity, Seg: seg[2]}, cityOf()
	case seg[1] == "Bike" && seg[2] == "Station":
		key, partVal = dataset.FamSeg{Family: dataset.FamilyBikeCity, Seg: "Station"}, cityOf()
	case seg[1] == "Rail" && len(seg) >= 4 && seg[2] == "Metro":
		key, partVal = dataset.FamSeg{Family: dataset.FamilyMetroSystem, Seg: seg[3]}, seg[len(seg)-1]
	case seg[1] == "Rail" && len(seg) == 3:
		key = dataset.FamSeg{Family: dataset.FamilyRailSingle, Seg: seg[2]}
	case seg[1] == "Rail" && len(seg) >= 4 && (seg[2] == "TRA" || seg[2] == "THSR"):
		pair := seg[2] + "/" + seg[3]
		if pair == "TRA/DailyTimetable" || pair == "THSR/DailyTimetable" {
			key, partVal = dataset.FamSeg{Family: dataset.FamilyRailDate, Seg: pair}, seg[len(seg)-1]
		} else {
			key = dataset.FamSeg{Family: dataset.FamilyRailSingle, Seg: pair}
		}
	default:
		return Target{}, false
	}
	d, found := dataset.RawTargetIndex[key]
	if !found {
		return Target{}, false
	}
	return Target{Table: d.RawTable, PartCol: d.PartCol, PartVal: partVal}, true
}

type Target struct {
	Table   string
	PartCol string
	PartVal string
}

// errRawDump marks a raw_tdx landing failure so callers can log it distinctly
// and, crucially, avoid caching a Last-Modified that would mask the failure.
var errRawDump = errors.New("raw dump failed")

// _stalePartitionAfter bounds how long a landing_state partition may go untouched
// before ReportStalePartitions names it.
const _stalePartitionAfter = 7 * 24 * time.Hour

// rawStateQuerier is the read-only slice of the pool ReportStalePartitions
// needs, so the sweep can be exercised without a database.
type rawStateQuerier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func ReportStalePartitions(ctx context.Context, db rawStateQuerier) int {
	if db == nil {
		return 0
	}
	rows, err := db.Query(ctx, `
		SELECT table_name, partition_value, fetched_at
		FROM raw_tdx.landing_state
		WHERE fetched_at < $1
		ORDER BY fetched_at, table_name, partition_value`, time.Now().Add(-_stalePartitionAfter))
	if err != nil {
		zap.S().Errorw("stale scan error",
			"component", "ingest",
			"action", "landing_state",
			"event", "stale_scan_error",
			"err", err,
		)
		return 0
	}
	defer rows.Close()
	var stale int
	for rows.Next() {
		var table, partition string
		var fetchedAt time.Time
		if err := rows.Scan(&table, &partition, &fetchedAt); err != nil {
			zap.S().Errorw("stale scan error",
				"component", "ingest",
				"action", "landing_state",
				"event", "stale_scan_error",
				"err", err,
			)
			return stale
		}
		stale++
		zap.S().Warnw("stale partition",
			"component", "ingest",
			"action", "landing_state",
			"event", "stale_partition",
			"table", table,
			"partition", partition,
			"fetched_at", fetchedAt.Format(time.RFC3339),
		)
	}
	if err := rows.Err(); err != nil {
		zap.S().Errorw("stale scan error",
			"component", "ingest",
			"action", "landing_state",
			"event", "stale_scan_error",
			"err", err,
		)
		return stale
	}
	if stale > 0 {
		zap.S().Warnw("stale summary",
			"component", "ingest",
			"action", "landing_state",
			"event", "stale_summary",
			"count", stale,
			"older_than", _stalePartitionAfter,
		)
	}
	return stale
}

var ErrLandingStateMismatch = errors.New("raw landing state mismatch")

type LandingStateMismatchError struct {
	Table    string
	PartCol  string
	PartVal  string
	Reason   string
	Expected string
	Observed string
}

func (e *LandingStateMismatchError) Error() string {
	return fmt.Sprintf("%v: table=%s partition=%s:%s reason=%s expected=%s observed=%s",
		ErrLandingStateMismatch, e.Table, e.PartCol, e.PartVal, e.Reason, e.Expected, e.Observed)
}

func (e *LandingStateMismatchError) Unwrap() error { return ErrLandingStateMismatch }

type LandingBeginner interface {
	Begin(context.Context) (pgx.Tx, error)
}

// SQL identifiers must come from the validated whitelist.
var TDXTables = buildWhitelist()

func buildWhitelist() map[string]bool {
	m := make(map[string]bool)
	for _, d := range dataset.Registry() {
		m[d.RawTable] = true
	}
	return m
}

func ValidateTarget(t Target) error {
	if !TDXTables[t.Table] {
		return _oops.With("table", t.Table).Wrapf(errRawDump, "table not whitelisted")
	}
	switch t.PartCol {
	case "", "city", "system", "traindate":
		return nil
	default:
		return _oops.With("part_col", t.PartCol).Wrapf(errRawDump, "partition column not allowed")
	}
}

// THSR uses Taipei-midnight timestamptz; TRA uses date text independent of the session timezone.
func PartitionWhere(t Target) string {
	if t.Table == "thsr_dailytimetable" {
		return "WHERE (traindate AT TIME ZONE 'Asia/Taipei')::date = $1::date"
	}
	return fmt.Sprintf("WHERE %s = $1", t.PartCol)
}

func VerifyAndTouchLanding(ctx context.Context, t Target, marker, landingCycle string) error {
	if DB == nil {
		return _oops.Wrapf(errRawDump, "ingestDB is nil")
	}
	return VerifyAndTouchLandingWithDB(ctx, DB, t, marker, landingCycle)
}

func VerifyAndTouchLandingWithDB(
	ctx context.Context,
	db LandingBeginner,
	t Target,
	marker, landingCycle string,
) error {
	table, partCol, partVal := t.Table, t.PartCol, t.PartVal
	if err := ValidateTarget(t); err != nil {
		return err
	}
	if marker == "" {
		return &LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "empty_marker", Expected: "non-empty", Observed: "empty",
		}
	}
	if strings.TrimSpace(landingCycle) == "" {
		return _oops.Wrapf(errRawDump, "landing cycle is empty")
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return _oops.Wrapf(err, "verify raw landing state: begin")
	}
	defer func() {
		rbCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(rbCtx)
	}()
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '20s'"); err != nil {
		return _oops.Wrapf(err, "verify raw landing state: set lock_timeout")
	}

	var stateMarker string
	var rowCount int64
	err = tx.QueryRow(ctx, `
		SELECT last_modified, row_count
		FROM raw_tdx.landing_state
		WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3
		FOR UPDATE`, table, partCol, partVal).Scan(&stateMarker, &rowCount)
	if errors.Is(err, pgx.ErrNoRows) {
		return &LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "missing_state", Expected: marker, Observed: "missing",
		}
	}
	if err != nil {
		return _oops.Wrapf(err, "verify raw landing state: read state")
	}
	if stateMarker != marker {
		return &LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "marker", Expected: stateMarker, Observed: marker,
		}
	}

	existsSQL := fmt.Sprintf("SELECT EXISTS (SELECT 1 FROM raw_tdx.%s", table)
	args := []any{}
	if partCol != "" {
		existsSQL += " " + PartitionWhere(t)
		args = append(args, partVal)
	}
	existsSQL += " LIMIT 1)"
	var hasRows bool
	if err := tx.QueryRow(ctx, existsSQL, args...).Scan(&hasRows); err != nil {
		return _oops.Wrapf(err, "verify raw landing state: inspect partition")
	}
	expectedRows := rowCount > 0
	if hasRows != expectedRows {
		return &LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "row_presence", Expected: fmt.Sprint(expectedRows), Observed: fmt.Sprint(hasRows),
		}
	}
	ct, err := tx.Exec(ctx, `
		UPDATE raw_tdx.landing_state SET fetched_at=now(), landing_cycle=$4
		WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3`, table, partCol, partVal, landingCycle)
	if err != nil {
		return _oops.Wrapf(err, "verify raw landing state: touch state")
	}
	if ct.RowsAffected() != 1 {
		return &LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "state_update", Expected: "1", Observed: fmt.Sprint(ct.RowsAffected()),
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return _oops.Wrapf(err, "verify raw landing state: commit")
	}
	return nil
}

// rawDeleteSQL builds the per-partition DELETE for a raw_tdx landing. The
// table and partition column are interpolated, so callers must pass a target
// already cleared by ValidateTarget.
func rawDeleteSQL(t Target) string {
	return fmt.Sprintf("DELETE FROM raw_tdx.%s %s", t.Table, PartitionWhere(t))
}

func rawInsertSQL(table string) string {
	return fmt.Sprintf(`INSERT INTO raw_tdx.%s
SELECT r.* FROM jsonb_array_elements($2::jsonb) elem,
  LATERAL jsonb_populate_record(NULL::raw_tdx.%s,
    (SELECT jsonb_object_agg(lower(e.k), e.v) FROM jsonb_each(elem) AS e(k,v)) || $1::jsonb) r`, table, table)
}

func Dump(ctx context.Context, t Target, marker, landingCycle string, body []byte) error {
	if DB == nil {
		return _oops.Wrapf(errRawDump, "ingestDB is nil")
	}
	return DumpWithDB(ctx, DB, t, marker, landingCycle, body)
}

// DumpWithDB is Dump with the pool passed explicitly, so tests can
// exercise it against a pool they own instead of reassigning DB.
func DumpWithDB(ctx context.Context, db LandingBeginner, t Target, marker, landingCycle string, body []byte) error {
	if len(body) == 0 {
		body = []byte("[]")
	}
	return dumpRawTDXReaderWithDB(ctx, db, t, marker, landingCycle, bytes.NewReader(body))
}

// A seekable body permits retries without retaining a second payload copy.
func DumpReader(ctx context.Context, t Target, marker, landingCycle string, body io.ReadSeeker) error {
	if DB == nil {
		return _oops.Wrapf(errRawDump, "ingestDB is nil")
	}
	return dumpRawTDXReaderWithDB(ctx, DB, t, marker, landingCycle, body)
}

func dumpRawTDXReaderWithDB(
	ctx context.Context,
	db LandingBeginner,
	t Target,
	marker, landingCycle string,
	body io.ReadSeeker,
) error {
	if err := ValidateTarget(t); err != nil {
		return err
	}
	if body == nil {
		return _oops.Wrapf(errRawDump, "response body is nil")
	}
	if strings.TrimSpace(marker) == "" {
		return _oops.Wrapf(errRawDump, "last-modified marker is empty")
	}
	if strings.TrimSpace(landingCycle) == "" {
		return _oops.Wrapf(errRawDump, "landing cycle is empty")
	}
	ArchivePayload(ctx, history.Target(), t, marker, landingCycle, body)
	return obs.Retry(ctx, 3, 2*time.Second, func() error {
		if _, err := body.Seek(0, io.SeekStart); err != nil {
			return _oops.Wrapf(err, "rewind response")
		}
		return obs.Transient(landRawTDXWithDB(ctx, db, t, marker, landingCycle, body))
	})
}

func landRawTDXWithDB(
	ctx context.Context,
	db LandingBeginner,
	t Target,
	marker, landingCycle string,
	body io.Reader,
) error {
	table, partCol, partVal := t.Table, t.PartCol, t.PartVal
	if err := ValidateTarget(t); err != nil {
		return err
	}
	if strings.TrimSpace(marker) == "" {
		return _oops.Wrapf(errRawDump, "last-modified marker is empty")
	}
	if strings.TrimSpace(landingCycle) == "" {
		return _oops.Wrapf(errRawDump, "landing cycle is empty")
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()

	tx, err := db.Begin(ctx)
	if err != nil {
		return _oops.Wrapf(err, "begin")
	}
	// Rollback must outlive request cancellation to release the transaction.
	defer func() {
		rbCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(rbCtx)
	}()

	// Bound lock waits so a held lock fails this attempt fast (retryable) instead of
	// stalling TRUNCATE/DELETE for the full landing deadline.
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '20s'"); err != nil {
		return _oops.Wrapf(err, "set lock_timeout")
	}

	inject := "{}"
	if partCol != "" {
		if _, err := tx.Exec(ctx, rawDeleteSQL(t), partVal); err != nil {
			return _oops.Wrapf(err, "delete partition")
		}
		b, _ := json.Marshal(map[string]string{partCol: partVal})
		inject = string(b)
	} else if _, err := tx.Exec(ctx, fmt.Sprintf("TRUNCATE raw_tdx.%s", table)); err != nil {
		return _oops.Wrapf(err, "truncate")
	}
	rows, err := insertRawChunks(ctx, func(ctx context.Context, sql string, args ...any) (int64, error) {
		ct, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return 0, err
		}
		return ct.RowsAffected(), nil
	}, table, inject, body)
	if err != nil {
		return _oops.Wrapf(err, "insert")
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO raw_tdx.landing_state
			(table_name, partition_column, partition_value, last_modified, row_count, fetched_at, landing_cycle)
		VALUES ($1, $2, $3, $4, $5, now(), $6)
		ON CONFLICT (table_name, partition_column, partition_value) DO UPDATE SET
			last_modified=EXCLUDED.last_modified,
			row_count=EXCLUDED.row_count,
			fetched_at=EXCLUDED.fetched_at,
			landing_cycle=EXCLUDED.landing_cycle`,
		table, partCol, partVal, marker, rows, landingCycle); err != nil {
		return _oops.Wrapf(err, "upsert landing state")
	}
	if err := tx.Commit(ctx); err != nil {
		return _oops.Wrapf(err, "commit")
	}
	zap.S().Infow("success", "component", "raw_tdx", "table", table, "rows", rows, "event", "success")
	return nil
}

const _rawChunkBytes = 4 << 20

func insertRawChunks(ctx context.Context, exec func(context.Context, string, ...any) (int64, error), table, inject string, body io.Reader) (int64, error) {
	dec := json.NewDecoder(body)
	// Split rather than folded into one condition: a well-formed token that is
	// simply not "[" carries no error to wrap, and Wrapf(nil) is nil — folding
	// the two would return a nil error for a non-array payload.
	tok, err := dec.Token()
	if err != nil {
		return 0, _oops.With("table", table).Wrapf(err, "read payload opening token")
	}
	if tok != json.Delim('[') {
		return 0, _oops.With("table", table).With("token", tok).Errorf("payload is not a JSON array")
	}
	sql := rawInsertSQL(table)
	chunk := append(make([]byte, 0, _rawChunkBytes+(1<<20)), '[')
	var rows int64
	flush := func() error {
		n, err := exec(ctx, sql, inject, append(chunk, ']'))
		if err != nil {
			return err
		}
		rows += n
		chunk = chunk[:1]
		return nil
	}
	flushed := false
	for dec.More() {
		var elem json.RawMessage
		if err := dec.Decode(&elem); err != nil {
			return rows, _oops.Wrapf(err, "decode array element")
		}
		if len(chunk) > 1 {
			chunk = append(chunk, ',')
		}
		chunk = append(chunk, elem...)
		if len(chunk) >= _rawChunkBytes {
			if err := flush(); err != nil {
				return rows, err
			}
			flushed = true
		}
	}
	closing, err := dec.Token()
	if err != nil {
		return rows, _oops.Wrapf(err, "decode array closing delimiter")
	}
	if closing != json.Delim(']') {
		return rows, _oops.With("closing", closing).Errorf("payload has invalid array closing token")
	}
	var trailing json.RawMessage
	switch err := dec.Decode(&trailing); {
	case errors.Is(err, io.EOF):
		// Only JSON whitespace may follow the closing array delimiter.
	case err != nil:
		return rows, _oops.Wrapf(err, "decode data after JSON array")
	default:
		return rows, errors.New("payload contains data after JSON array")
	}
	if len(chunk) > 1 || !flushed {
		if err := flush(); err != nil {
			return rows, err
		}
	}
	return rows, nil
}
