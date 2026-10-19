package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/bike"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/mrt"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/rail"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

type loadSpec struct {
	key        string
	table      string
	partCol    string
	partitions func() []string
	load       func(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, part string) error
	loadFull   func(ctx context.Context, dec *json.Decoder, sink loadSink, part string) error
	report     []qualityTarget
	staleOK    bool
}

type qualityTarget struct {
	table    string
	textCols []string
	geoCols  []string
}

// errLoadStale marks a partition whose durable landing-state fetched_at is
// older than the freshness window; the loader skips it rather than overwriting
// good data with a landing that never happened.
var errLoadStale = errors.New("raw_tdx_partition_stale")

type loadStats struct {
	ok      int
	failed  int
	skipped int
}

// runLoad transforms the named datasets from src into db (and rc for the
// Redis-only datasets). keys selects registry entries by loadSpec.key; an empty
// keys slice loads every registered dataset.
func runLoad(ctx context.Context, src pipeline.LoadSource, db *pgxpool.Pool, rc *redis.Client, keys []string) (loadStats, error) {
	return runLoadSpecs(ctx, src, db, rc, selectLoadSpecs(loaderRegistry(src), keys))
}

func selectLoadSpecs(specs []loadSpec, keys []string) []loadSpec {
	if len(keys) == 0 {
		return specs
	}
	want := selectedLoadKeys(keys)
	filtered := specs[:0:0]
	for _, spec := range specs {
		if want[spec.key] {
			filtered = append(filtered, spec)
		}
	}
	return filtered
}

func selectedLoadKeys(keys []string) map[string]bool {
	want := make(map[string]bool, len(keys))
	for _, key := range keys {
		want[key] = true
	}
	return want
}

func runLoadSpecs(ctx context.Context, src pipeline.LoadSource, db *pgxpool.Pool, rc *redis.Client, specs []loadSpec) (loadStats, error) {
	sink := pgLoadSink{db: db, rc: rc}
	var stats loadStats
	var failures []error
	for _, spec := range specs {
		partStats, partFailures := runLoadSpec(ctx, src, sink, spec)
		stats.add(partStats)
		failures = append(failures, partFailures...)
		reportQuality(ctx, db, spec)
	}
	zap.S().Infow("done", "component", "load", "action", "run", "event", "done",
		"ok", stats.ok, "failed", stats.failed, "skipped", stats.skipped)
	return stats, errors.Join(failures...)
}

func (stats *loadStats) add(other loadStats) {
	stats.ok += other.ok
	stats.failed += other.failed
	stats.skipped += other.skipped
}

func runLoadSpec(ctx context.Context, src pipeline.LoadSource, sink pgLoadSink, spec loadSpec) (loadStats, []error) {
	var stats loadStats
	var failures []error
	for _, part := range spec.partitions() {
		partStats, err := loadDatasetPartition(ctx, src, sink, spec, part)
		stats.add(partStats)
		if err != nil {
			failures = append(failures, err)
		}
	}
	return stats, failures
}

func loadDatasetPartition(ctx context.Context, src pipeline.LoadSource, sink pgLoadSink, spec loadSpec, part string) (loadStats, error) {
	body, fetchedAt, err := src.DatasetJSON(ctx, spec.table, spec.partCol, part)
	if err != nil {
		return loadStats{failed: 1}, _oops.With("spec_key", spec.key).With("part", part).Wrapf(err, "load dataset partition: read")
	}
	return loadFetchedPartition(ctx, body, fetchedAt, sink, spec, part)
}

func loadFetchedPartition(ctx context.Context, body []byte, fetchedAt time.Time, sink pgLoadSink, spec loadSpec, part string) (loadStats, error) {
	if fetchedAt.IsZero() {
		zap.S().Warnw("never landed", "component", "load", "action", "skip", "event", "never_landed", "dataset", spec.key, "partition", part)
		return loadStats{skipped: 1}, nil
	}
	if err := validateLoadPartitionAge(spec, part, fetchedAt); err != nil {
		return loadStats{failed: 1}, err
	}
	return transformLoadPartition(ctx, body, sink, spec, part)
}

func validateLoadPartitionAge(spec loadSpec, part string, fetchedAt time.Time) error {
	if spec.staleOK {
		return nil
	}
	if raw.IsStale(fetchedAt) {
		return _oops.With("spec_key", spec.key).With("part", part).With("fetched_at", fetchedAt.Format(time.RFC3339)).Wrapf(errLoadStale, "load dataset partition fetched_at")
	}
	return nil
}

func transformLoadPartition(ctx context.Context, body []byte, sink pgLoadSink, spec loadSpec, part string) (loadStats, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	transform := loadSpecTransform(spec, sink)
	if err := transform(ctx, dec, sink, part); err != nil {
		return loadStats{failed: 1}, _oops.With("spec_key", spec.key).With("part", part).Wrapf(err, "load dataset partition: transform")
	}
	zap.S().Infow("success", "component", "load", "action", "transform", "event", "success", "dataset", spec.key, "partition", part)
	return loadStats{ok: 1}, nil
}

func reportQuality(ctx context.Context, db *pgxpool.Pool, spec loadSpec) {
	for _, target := range spec.report {
		reportTableQuality(ctx, db, spec.key, target)
	}
}

func qualityReportQuery(target qualityTarget) (string, []string) {
	selects := []string{"COUNT(*) AS rows"}
	var cols []string
	for _, column := range target.textCols {
		selects = append(selects, fmt.Sprintf("COUNT(*) FILTER (WHERE %q IS NULL OR %q = '') AS %s_empty", column, column, column))
		cols = append(cols, column)
	}
	for _, column := range target.geoCols {
		selects = append(selects, fmt.Sprintf("COUNT(*) FILTER (WHERE %q IS NULL) AS %s_empty", column, column))
		cols = append(cols, column)
	}
	return fmt.Sprintf("SELECT %s FROM %s", strings.Join(selects, ", "), target.table), cols
}

func reportTableQuality(ctx context.Context, db *pgxpool.Pool, datasetKey string, target qualityTarget) {
	query, cols := qualityReportQuery(target)
	vals := make([]int64, 1+len(cols))
	dest := qualityReportDestinations(vals)
	if err := db.QueryRow(ctx, query).Scan(dest...); err != nil {
		zap.S().Errorw("query error", "component", "load", "action", "quality_report", "event", "query_error", "dataset", datasetKey, "table", target.table, "err", err)
		return
	}
	zap.S().Infow("quality report", "component", "load", "action", "quality_report", "dataset", datasetKey,
		"table", target.table, "rows", vals[0], "empty_ratios", qualityReportRatios(cols, vals))
}

func qualityReportDestinations(vals []int64) []any {
	dest := make([]any, len(vals))
	for i := range vals {
		dest[i] = &vals[i]
	}
	return dest
}

func qualityReportRatios(cols []string, vals []int64) map[string]float64 {
	// Separate fields keep empty ratios queryable by column in the log backend.
	ratios := make(map[string]float64, len(cols))
	for i, column := range cols {
		if vals[0] > 0 {
			ratios[column] = float64(vals[i+1]) / float64(vals[0])
		}
	}
	return ratios
}

type rawReadTxBeginner interface {
	BeginTx(context.Context, pgx.TxOptions) (pgx.Tx, error)
}

type rawTDXSource struct {
	pool rawReadTxBeginner
}

func (r rawTDXSource) DatasetJSON(ctx context.Context, table, partCol, partVal string) ([]byte, time.Time, error) {
	body, fetchedAt, _, err := r.readDatasetJSON(ctx, table, partCol, partVal, false /* includeCycle */)
	return body, fetchedAt, err
}

func (r rawTDXSource) DatasetJSONWithLandingCycle(ctx context.Context, table, partCol, partVal string) ([]byte, time.Time, string, error) {
	return r.readDatasetJSON(ctx, table, partCol, partVal, true /* includeCycle */)
}

type rawDatasetLandingState struct {
	fetchedAt time.Time
	rowCount  int64
	cycle     string
}

func (r rawTDXSource) readDatasetJSON(ctx context.Context, table, partCol, partVal string, includeCycle bool) ([]byte, time.Time, string, error) {
	target := raw.Target{Table: table, PartCol: partCol, PartVal: partVal}
	if err := raw.ValidateTarget(target); err != nil {
		return nil, time.Time{}, "", err
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, time.Time{}, "", _oops.With("table", table).With("part_val", partVal).Wrapf(err, "read raw dataset partition: begin")
	}
	defer func() {
		rbCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(rbCtx)
	}()
	state, err := readRawDatasetLandingState(ctx, tx, target, includeCycle)
	if err != nil {
		return nil, time.Time{}, "", err
	}
	return readLandedDatasetJSON(ctx, tx, target, state)
}

func readLandedDatasetJSON(ctx context.Context, tx pgx.Tx, target raw.Target, state *rawDatasetLandingState) ([]byte, time.Time, string, error) {
	if state == nil {
		return []byte("[]"), time.Time{}, "", nil
	}
	body, err := readCommittedRawDataset(ctx, tx, target, state)
	if err != nil {
		return nil, time.Time{}, "", err
	}
	return body, state.fetchedAt, state.cycle, nil
}

func readCommittedRawDataset(ctx context.Context, tx pgx.Tx, target raw.Target, state *rawDatasetLandingState) ([]byte, error) {
	body, err := readVerifiedRawDataset(ctx, tx, target, state.rowCount)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, _oops.With("table", target.Table).With("part_val", target.PartVal).Wrapf(err, "read raw dataset partition: commit")
	}
	return body, nil
}

func readVerifiedRawDataset(ctx context.Context, tx pgx.Tx, target raw.Target, expectedRows int64) ([]byte, error) {
	body, count, err := readRawDatasetRows(ctx, tx, target)
	if err != nil {
		return nil, err
	}
	if count != expectedRows {
		return nil, &raw.LandingStateMismatchError{Table: target.Table, PartCol: target.PartCol, PartVal: target.PartVal, Reason: "loader_row_count", Expected: fmt.Sprint(expectedRows), Observed: fmt.Sprint(count)}
	}
	return body, nil
}

func readRawDatasetLandingState(ctx context.Context, tx pgx.Tx, target raw.Target, includeCycle bool) (*rawDatasetLandingState, error) {
	row := tx.QueryRow(ctx, rawLandingStateQuery(includeCycle), target.Table, target.PartCol, target.PartVal)
	state, err := scanRawLandingState(row, includeCycle)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, _oops.With("table", target.Table).With("part_val", target.PartVal).Wrapf(err, "read raw dataset partition: landing state")
	}
	return state, nil
}

func rawLandingStateQuery(includeCycle bool) string {
	if includeCycle {
		return `SELECT fetched_at, row_count, COALESCE(landing_cycle, '')
			FROM raw_tdx.landing_state
			WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3`
	}
	return `SELECT fetched_at, row_count FROM raw_tdx.landing_state
		WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3`
}

func scanRawLandingState(row pgx.Row, includeCycle bool) (*rawDatasetLandingState, error) {
	state := &rawDatasetLandingState{}
	dest := []any{&state.fetchedAt, &state.rowCount}
	if includeCycle {
		dest = append(dest, &state.cycle)
	}
	return state, row.Scan(dest...)
}

func rawDatasetQuery(target raw.Target) (string, []any) {
	strip := "ARRAY['fetched_at']::text[]"
	if target.PartCol != "" {
		strip = fmt.Sprintf("ARRAY['fetched_at','%s']::text[]", target.PartCol)
	}
	elem := fmt.Sprintf("(to_jsonb(t) - %s)", strip)
	if target.Table == "thsr_dailytimetable" {
		// Re-insert traindate as a YYYY-MM-DD string. When traindate is the
		// partition column it was stripped above; jsonb || sets it either way.
		elem = fmt.Sprintf("(%s || jsonb_build_object('traindate', to_char(t.traindate, 'YYYY-MM-DD')))", elem)
	}
	where := ""
	args := []any{}
	if target.PartCol != "" {
		where = raw.PartitionWhere(target)
		args = append(args, target.PartVal)
	}
	q := fmt.Sprintf(
		`SELECT %s::text FROM raw_tdx.%s t %s`,
		elem, target.Table, where)
	return q, args
}
func readRawDatasetRows(ctx context.Context, tx pgx.Tx, target raw.Target) ([]byte, int64, error) {
	q, args := rawDatasetQuery(target)
	rows, err := tx.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, _oops.With("table", target.Table).With("part_val", target.PartVal).Wrapf(err, "read raw dataset partition: query rows")
	}
	defer rows.Close()
	return assembleRawDatasetRows(rows, target)
}

func assembleRawDatasetRows(rows pgx.Rows, target raw.Target) ([]byte, int64, error) {
	var buf bytes.Buffer
	buf.WriteByte('[')
	var actualRows int64
	for rows.Next() {
		if err := appendRawDatasetRow(&buf, rows, target); err != nil {
			return nil, 0, err
		}
		actualRows++
	}
	return finishRawDatasetRows(&buf, rows, target, actualRows)
}

func appendRawDatasetRow(buf *bytes.Buffer, rows pgx.Rows, target raw.Target) error {
	var rowJSON []byte
	if err := rows.Scan(&rowJSON); err != nil {
		return _oops.With("table", target.Table).With("part_val", target.PartVal).Wrapf(err, "read raw dataset partition: scan row")
	}
	if buf.Len() > 1 {
		buf.WriteByte(',')
	}
	buf.Write(rowJSON)
	return nil
}

func finishRawDatasetRows(buf *bytes.Buffer, rows pgx.Rows, target raw.Target, actualRows int64) ([]byte, int64, error) {
	if err := rows.Err(); err != nil {
		return nil, 0, _oops.With("table", target.Table).With("part_val", target.PartVal).Wrapf(err, "read raw dataset partition: rows")
	}
	buf.WriteByte(']')
	rows.Close()
	return buf.Bytes(), actualRows, nil
}

func loadSpecTransform(spec loadSpec, sink pgLoadSink) func(context.Context, *json.Decoder, pipeline.CopyUpsertSink, string) error {
	transform := spec.load
	if transform == nil {
		full := spec.loadFull
		transform = func(ctx context.Context, dec *json.Decoder, _ pipeline.CopyUpsertSink, part string) error {
			return full(ctx, dec, sink, part)
		}
	}
	return transform
}

type loaderBinding struct {
	load     func(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, part string) error
	loadFull func(ctx context.Context, dec *json.Decoder, sink loadSink, part string) error
	report   []qualityTarget
}

func loaderTransforms(src pipeline.LoadSource) map[string]loaderBinding {
	return map[string]loaderBinding{
		"bus": {
			loadFull: func(ctx context.Context, _ *json.Decoder, sink loadSink, part string) error {
				return sink.loadBusCity(ctx, src, part)
			},
			report: []qualityTarget{
				{table: "bus_subroutes", textCols: []string{"route_name", "sub_route_name", "depart", "destin"}},
				{table: "bus_static", textCols: []string{"route_name", "sub_route_name"}},
				{table: "bus_stations", textCols: []string{"station_name"}, geoCols: []string{"position"}},
			}},
		"bus_dailytimetable": {loadFull: func(ctx context.Context, dec *json.Decoder, sink loadSink, part string) error {
			return sink.loadBusDailyTimetable(ctx, dec, src, part)
		}},
		"bus_displaystop": {load: bus.LoadDisplayStops},
		"bike": {load: bike.LoadStations,
			report: []qualityTarget{{table: "bike_stations", textCols: []string{"name", "address"}, geoCols: []string{"geom"}}}},
		"mrt_station": {load: mrt.LoadStations,
			report: []qualityTarget{{table: "mrt_station", textCols: []string{"name"}, geoCols: []string{"stationposition"}}}},
		"mrt_firstlast": {load: mrt.LoadFirstlast},
		"mrt_odfare": {loadFull: func(ctx context.Context, dec *json.Decoder, sink loadSink, part string) error {
			return sink.loadMrtJourneyMatrix(ctx, dec, part)
		}},
		"mrt_traveltime": {loadFull: func(ctx context.Context, _ *json.Decoder, sink loadSink, part string) error {
			return sink.loadMrtTravelTime(ctx, src, part)
		}},
		"tra_station": {load: rail.LoadTraStation,
			report: []qualityTarget{{table: "tra_stations", textCols: []string{"name"}, geoCols: []string{"geom"}}}},
		"thsr_station": {
			loadFull: func(ctx context.Context, dec *json.Decoder, sink loadSink, part string) error {
				return sink.loadThsrStations(ctx, dec, part)
			},
			report: []qualityTarget{{table: "thsr_stations", textCols: []string{"name"}, geoCols: []string{"geom"}}}},
		"tra_fare":       {load: rail.LoadTraFare},
		"thsr_fare":      {load: rail.LoadThsrFare},
		"tra_timetable":  {load: rail.LoadTraTimetable},
		"thsr_timetable": {load: rail.LoadThsrTimetable},
		"tra_shape":      {load: rail.LoadShape("tra")},
		"thsr_shape":     {load: rail.LoadShape("thsr")},
		"metro_shape":    {load: rail.LoadShape("metro")},
	}
}

func loaderRegistry(src pipeline.LoadSource) []loadSpec {
	transforms := loaderTransforms(src)
	var specs []loadSpec
	for _, d := range dataset.Registry() {
		if d.LoadKey == "" {
			continue
		}
		b := transforms[d.LoadKey]
		specs = append(specs, loadSpec{
			key:        d.LoadKey,
			table:      d.RawTable,
			partCol:    d.PartCol,
			partitions: d.LoadPartitions,
			load:       b.load,
			loadFull:   b.loadFull,
			report:     b.report,
			staleOK:    d.StaleOK,
		})
	}
	specs = append(specs, loadSpec{
		key:        "mrt_adjacency",
		table:      "metro_s2straveltime",
		partCol:    "system",
		partitions: func() []string { return dataset.MetroS2STravelTime },
		load:       mrt.LoadAdjacency,
	})
	return specs
}
