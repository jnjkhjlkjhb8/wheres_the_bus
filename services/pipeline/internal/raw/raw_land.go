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
	q, arg := rawSinceQuery(name)
	timestamp, err := readRawSince(q, arg)
	return formatRawSince(timestamp, err)
}

func readRawSince(query string, arg any) (*time.Time, error) {
	args := []any{}
	if arg != nil {
		args = append(args, arg)
	}
	var timestamp *time.Time
	err := DB.QueryRow(context.Background(), query, args...).Scan(&timestamp)
	return timestamp, err
}

func formatRawSince(timestamp *time.Time, err error) string {
	if err != nil || timestamp == nil {
		return ""
	}
	return timestamp.UTC().Format(http.TimeFormat)
}

func rawSinceQuery(name string) (string, any) {
	exact := map[string]string{
		"tra_stations":  "SELECT MAX(updated_at) FROM tra_stations",
		"thsr_stations": "SELECT MAX(updated_at) FROM thsr_stations",
		"tra_fare":      "SELECT MAX(updated_at) FROM tra_fares",
		"thsr_fare":     "SELECT MAX(updated_at) FROM thsr_fares",
	}
	if q, ok := exact[name]; ok {
		return q, nil
	}
	for _, spec := range []struct{ prefix, table, column string }{
		{"tra_traindate_", "tra_timetable", "train_date"},
		{"thsr_traindate_", "thsr_timetable", "train_date"},
		{"mrt_stations", "mrt_station", "system"},
		{"mrt_firstlast", "mrt_schedule", "system"},
		{"bike_stations", "bike_stations", "city"},
	} {
		if strings.HasPrefix(name, spec.prefix) {
			return "SELECT MAX(updated_at) FROM " + spec.table + " WHERE " + spec.column + "=$1", strings.TrimPrefix(name, spec.prefix)
		}
	}
	return "", nil
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
	seg := strings.Split(strings.Trim(url, "/"), "/")
	if !validRawURLSegments(seg) {
		return Target{}, false
	}
	key, partVal, found := rawURLFamily(seg)
	if !found {
		return Target{}, false
	}
	d, found := dataset.RawTargetIndex[key]
	if !found {
		return Target{}, false
	}
	return Target{Table: d.RawTable, PartCol: d.PartCol, PartVal: partVal}, true
}
func validRawURLSegments(seg []string) bool { return len(seg) >= 3 && seg[0] == "v2" }

func rawURLCity(seg []string) string {
	for i := range seg {
		if city := rawURLCitySegment(seg, i); city != "" {
			return city
		}
	}
	return ""
}

func rawURLCitySegment(seg []string, i int) string {
	if seg[i] == "InterCity" {
		return "InterCity"
	}
	if seg[i] == "City" {
		return rawCityAfterSegment(seg, i)
	}
	return ""
}

func rawCityAfterSegment(seg []string, index int) string {
	if index+1 < len(seg) {
		return seg[index+1]
	}
	return ""
}

var _rawURLFamilies = map[string]func([]string) (dataset.FamSeg, string, bool){
	"Bus": rawBusURLFamily, "Bike": rawBikeURLFamily, "Rail": rawRailURLFamily,
}

func rawURLFamily(seg []string) (dataset.FamSeg, string, bool) {
	family := _rawURLFamilies[seg[1]]
	if family == nil {
		return dataset.FamSeg{}, "", false
	}
	return family(seg)
}

func rawBusURLFamily(seg []string) (dataset.FamSeg, string, bool) {
	return dataset.FamSeg{Family: dataset.FamilyBusCity, Seg: seg[2]}, rawURLCity(seg), true
}

func rawBikeURLFamily(seg []string) (dataset.FamSeg, string, bool) {
	if seg[2] == "Station" {
		return dataset.FamSeg{Family: dataset.FamilyBikeCity, Seg: "Station"}, rawURLCity(seg), true
	}
	return dataset.FamSeg{}, "", false
}

func rawRailURLFamily(seg []string) (dataset.FamSeg, string, bool) {
	// Three-segment rail targets take precedence over metro partition routing.
	if len(seg) == 3 {
		return dataset.FamSeg{Family: dataset.FamilyRailSingle, Seg: seg[2]}, "", true
	}
	if seg[2] == "Metro" {
		return dataset.FamSeg{Family: dataset.FamilyMetroSystem, Seg: seg[3]}, seg[len(seg)-1], true
	}
	return rawTrainURLFamily(seg)
}

var _rawTrainSystems = map[string]bool{"TRA": true, "THSR": true}
var _rawDailyTrainTargets = map[string]bool{"TRA/DailyTimetable": true, "THSR/DailyTimetable": true}

func rawTrainURLFamily(seg []string) (dataset.FamSeg, string, bool) {
	if !_rawTrainSystems[seg[2]] {
		return dataset.FamSeg{}, "", false
	}
	pair := seg[2] + "/" + seg[3]
	if _rawDailyTrainTargets[pair] {
		return dataset.FamSeg{Family: dataset.FamilyRailDate, Seg: pair}, seg[len(seg)-1], true
	}
	return dataset.FamSeg{Family: dataset.FamilyRailSingle, Seg: pair}, "", true
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
	return reportStaleRows(rows)
}

func reportStaleRows(rows pgx.Rows) int {
	stale := 0
	for rows.Next() {
		if !reportStalePartitionRow(rows) {
			return stale
		}
		stale++
	}
	return reportStaleSummary(rows.Err(), stale)
}

func reportStalePartitionRow(rows pgx.Rows) bool {
	var table, partition string
	var fetchedAt time.Time
	if err := rows.Scan(&table, &partition, &fetchedAt); err != nil {
		zap.S().Errorw("stale scan error",
			"component", "ingest",
			"action", "landing_state",
			"event", "stale_scan_error",
			"err", err,
		)
		return false
	}
	zap.S().Warnw("stale partition",
		"component", "ingest",
		"action", "landing_state",
		"event", "stale_partition",
		"table", table,
		"partition", partition,
		"fetched_at", fetchedAt.Format(time.RFC3339),
	)
	return true
}

func reportStaleSummary(scanErr error, stale int) int {

	if err := scanErr; err != nil {
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
	if err := validateRawLandingVerification(t, marker, landingCycle); err != nil {
		return err
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
	return verifyAndTouchRawTransaction(ctx, tx, t, marker, landingCycle)
}

func verifyAndTouchRawTransaction(ctx context.Context, tx pgx.Tx, t Target, marker, landingCycle string) error {
	if err := verifyLockedRawLanding(ctx, tx, t, marker); err != nil {
		return err
	}
	if err := touchRawLandingState(ctx, tx, t, landingCycle); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return _oops.Wrapf(err, "verify raw landing state: commit")
	}
	return nil
}

func verifyLockedRawLanding(ctx context.Context, tx pgx.Tx, t Target, marker string) error {
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '20s'"); err != nil {
		return _oops.Wrapf(err, "verify raw landing state: set lock_timeout")
	}

	rowCount, err := verifyRawLandingMarker(ctx, tx, t, marker)
	if err != nil {
		return err
	}
	if err := verifyRawLandingPresence(ctx, tx, t, rowCount); err != nil {
		return err
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

func validateRawMarkerInput(marker, landingCycle string) error {
	if strings.TrimSpace(marker) == "" {
		return _oops.Wrapf(errRawDump, "last-modified marker is empty")
	}
	if strings.TrimSpace(landingCycle) == "" {
		return _oops.Wrapf(errRawDump, "landing cycle is empty")
	}
	return nil
}

func validateRawReaderInput(t Target, marker, landingCycle string, body io.ReadSeeker) error {
	if err := ValidateTarget(t); err != nil {
		return err
	}
	if body == nil {
		return _oops.Wrapf(errRawDump, "response body is nil")
	}
	return validateRawMarkerInput(marker, landingCycle)
}

func dumpRawTDXReaderWithDB(
	ctx context.Context,
	db LandingBeginner,
	t Target,
	marker, landingCycle string,
	body io.ReadSeeker,
) error {
	if err := validateRawReaderInput(t, marker, landingCycle, body); err != nil {
		return err
	}
	ArchivePayload(ctx, history.Target(), t, marker, landingCycle, body)
	return obs.Retry(ctx, 3, 2*time.Second, func() error {
		return retryRawLanding(ctx, db, t, marker, landingCycle, body)
	})
}

func retryRawLanding(ctx context.Context, db LandingBeginner, t Target, marker, landingCycle string, body io.ReadSeeker) error {
	if _, err := body.Seek(0, io.SeekStart); err != nil {
		return _oops.Wrapf(err, "rewind response")
	}
	return obs.Transient(landRawTDXWithDB(ctx, db, t, marker, landingCycle, body))
}

func landRawTDXWithDB(
	ctx context.Context,
	db LandingBeginner,
	t Target,
	marker, landingCycle string,
	body io.Reader,
) error {
	if err := validateRawLandingInput(t, marker, landingCycle); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()

	return runRawLandingTransaction(ctx, db, t, marker, landingCycle, body)
}

func runRawLandingTransaction(ctx context.Context, db LandingBeginner, t Target, marker, landingCycle string, body io.Reader) error {
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

	rows, err := writeRawLandingRows(ctx, tx, t, body)
	if err != nil {
		return err
	}
	if err := writeRawLandingState(ctx, tx, t, marker, landingCycle, rows); err != nil {
		return err
	}
	return commitRawLanding(ctx, tx, t.Table, rows)
}

func writeRawLandingRows(ctx context.Context, tx pgx.Tx, t Target, body io.Reader) (int64, error) {
	// Bound lock waits so a held lock fails this attempt fast (retryable) instead of
	// stalling TRUNCATE/DELETE for the full landing deadline.
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '20s'"); err != nil {
		return 0, _oops.Wrapf(err, "set lock_timeout")
	}

	inject, err := clearRawLandingPartition(ctx, tx, t)
	if err != nil {
		return 0, err
	}
	rows, err := insertRawChunks(ctx, rawLandingExecutor(tx), t.Table, inject, body)
	if err != nil {
		return 0, _oops.Wrapf(err, "insert")
	}
	return rows, nil
}

func writeRawLandingState(ctx context.Context, tx pgx.Tx, t Target, marker, landingCycle string, rows int64) error {
	table, partCol, partVal := t.Table, t.PartCol, t.PartVal
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
	return nil
}

func commitRawLanding(ctx context.Context, tx pgx.Tx, table string, rows int64) error {
	if err := tx.Commit(ctx); err != nil {
		return _oops.Wrapf(err, "commit")
	}
	zap.S().Infow("success", "component", "raw_tdx", "table", table, "rows", rows, "event", "success")
	return nil
}

const _rawChunkBytes = 4 << 20

type rawChunkWriter struct {
	ctx         context.Context
	exec        func(context.Context, string, ...any) (int64, error)
	sql, inject string
	chunk       []byte
	rows        int64
	flushed     bool
}

func insertRawChunks(ctx context.Context, exec func(context.Context, string, ...any) (int64, error), table, inject string, body io.Reader) (int64, error) {
	dec, err := rawArrayDecoder(body, table)
	if err != nil {
		return 0, err
	}
	writer := rawChunkWriter{ctx: ctx, exec: exec, sql: rawInsertSQL(table), inject: inject, chunk: append(make([]byte, 0, _rawChunkBytes+(1<<20)), '[')}
	if err := writer.consume(dec); err != nil {
		return writer.rows, err
	}
	err = writer.finish(dec)
	return writer.rows, err
}
func (w *rawChunkWriter) shouldFlush() bool { return len(w.chunk) > 1 || !w.flushed }

func (w *rawChunkWriter) finish(dec *json.Decoder) error {
	if err := finishRawArray(dec); err != nil {
		return err
	}
	if w.shouldFlush() {
		return w.flush()
	}
	return nil
}

func rawArrayDecoder(body io.Reader, table string) (*json.Decoder, error) {
	dec := json.NewDecoder(body)
	// A well-formed non-array token has no error to wrap; Wrapf(nil) would accept it.
	tok, err := dec.Token()
	if err != nil {
		return nil, _oops.With("table", table).Wrapf(err, "read payload opening token")
	}
	if tok != json.Delim('[') {
		return nil, _oops.With("table", table).With("token", tok).Errorf("payload is not a JSON array")
	}
	return dec, nil
}
func (w *rawChunkWriter) flush() error {
	n, err := w.exec(w.ctx, w.sql, w.inject, append(w.chunk, ']'))
	if err != nil {
		return err
	}
	w.rows += n
	w.chunk = w.chunk[:1]
	w.flushed = true
	return nil
}
func (w *rawChunkWriter) consume(dec *json.Decoder) error {
	for dec.More() {
		if err := w.consumeElement(dec); err != nil {
			return err
		}
	}
	return nil
}

func (w *rawChunkWriter) consumeElement(dec *json.Decoder) error {
	var elem json.RawMessage
	if err := dec.Decode(&elem); err != nil {
		return _oops.Wrapf(err, "decode array element")
	}
	return w.appendElement(elem)
}

func (w *rawChunkWriter) appendElement(elem json.RawMessage) error {
	if len(w.chunk) > 1 {
		w.chunk = append(w.chunk, ',')
	}
	w.chunk = append(w.chunk, elem...)
	if len(w.chunk) >= _rawChunkBytes {
		return w.flush()
	}
	return nil
}
func finishRawArray(dec *json.Decoder) error {
	closing, err := dec.Token()
	if err != nil {
		return _oops.Wrapf(err, "decode array closing delimiter")
	}
	if closing != json.Delim(']') {
		return _oops.With("closing", closing).Errorf("payload has invalid array closing token")
	}
	return rejectRawTrailingData(dec)
}

func rejectRawTrailingData(dec *json.Decoder) error {
	var trailing json.RawMessage
	err := dec.Decode(&trailing)
	if errors.Is(err, io.EOF) {
		// Only JSON whitespace may follow the closing array delimiter.
		return nil
	}
	if err != nil {
		return _oops.Wrapf(err, "decode data after JSON array")
	}
	return errors.New("payload contains data after JSON array")
}

func validateRawLandingVerification(t Target, marker, landingCycle string) error {
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
	return nil
}
func verifyRawLandingMarker(ctx context.Context, tx pgx.Tx, t Target, marker string) (int64, error) {
	table, partCol, partVal := t.Table, t.PartCol, t.PartVal
	var stateMarker string
	var rowCount int64
	err := tx.QueryRow(ctx, `
		SELECT last_modified, row_count
		FROM raw_tdx.landing_state
		WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3
		FOR UPDATE`, table, partCol, partVal).Scan(&stateMarker, &rowCount)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, &LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "missing_state", Expected: marker, Observed: "missing",
		}
	}
	if err != nil {
		return 0, _oops.Wrapf(err, "verify raw landing state: read state")
	}
	if stateMarker != marker {
		return 0, &LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "marker", Expected: stateMarker, Observed: marker,
		}
	}

	return rowCount, nil
}
func verifyRawLandingPresence(ctx context.Context, tx pgx.Tx, t Target, rowCount int64) error {
	table, partCol, partVal := t.Table, t.PartCol, t.PartVal
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
	return nil
}
func touchRawLandingState(ctx context.Context, tx pgx.Tx, t Target, landingCycle string) error {
	table, partCol, partVal := t.Table, t.PartCol, t.PartVal
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
	return nil
}

func validateRawLandingInput(t Target, marker, landingCycle string) error {
	if err := ValidateTarget(t); err != nil {
		return err
	}
	return validateRawMarkerInput(marker, landingCycle)
}
func clearRawLandingPartition(ctx context.Context, tx pgx.Tx, t Target) (string, error) {
	table, partCol, partVal := t.Table, t.PartCol, t.PartVal
	inject := "{}"
	if partCol != "" {
		if _, err := tx.Exec(ctx, rawDeleteSQL(t), partVal); err != nil {
			return "", _oops.Wrapf(err, "delete partition")
		}
		b, _ := json.Marshal(map[string]string{partCol: partVal})
		inject = string(b)
	} else if _, err := tx.Exec(ctx, fmt.Sprintf("TRUNCATE raw_tdx.%s", table)); err != nil {
		return "", _oops.Wrapf(err, "truncate")
	}
	return inject, nil
}
func rawLandingExecutor(tx pgx.Tx) func(context.Context, string, ...any) (int64, error) {
	return func(ctx context.Context, sql string, args ...any) (int64, error) {
		ct, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return 0, err
		}
		return ct.RowsAffected(), nil
	}
}
