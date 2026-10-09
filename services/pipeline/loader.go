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
	specs := loaderRegistry(src)
	if len(keys) > 0 {
		want := map[string]bool{}
		for _, k := range keys {
			want[k] = true
		}
		filtered := specs[:0:0]
		for _, s := range specs {
			if want[s.key] {
				filtered = append(filtered, s)
			}
		}
		specs = filtered
	}
	return runLoadSpecs(ctx, src, db, rc, specs)
}

func runLoadSpecs(ctx context.Context, src pipeline.LoadSource, db *pgxpool.Pool, rc *redis.Client, specs []loadSpec) (loadStats, error) {
	sink := pgLoadSink{db: db, rc: rc}
	var stats loadStats
	var failures []error
	for _, spec := range specs {
		parts := spec.partitions()
		for _, part := range parts {
			body, fetchedAt, err := src.DatasetJSON(ctx, spec.table, spec.partCol, part)
			if err != nil {
				failures = append(failures, _oops.With("spec_key", spec.key).With("part", part).Wrapf(err, "load dataset partition: read"))
				stats.failed++
				continue
			}
			if fetchedAt.IsZero() {
				zap.S().Warnw("never landed",
					"component", "load",
					"action", "skip",
					"event", "never_landed",
					"dataset", spec.key,
					"partition", part,
				)
				stats.skipped++
				continue
			}
			if !spec.staleOK && raw.IsStale(fetchedAt) {
				failures = append(failures, _oops.With("spec_key", spec.key).With("part", part).With("fetched_at", fetchedAt.Format(time.RFC3339)).Wrapf(errLoadStale, "load dataset partition fetched_at"))
				stats.failed++
				continue
			}
			dec := json.NewDecoder(bytes.NewReader(body))
			transform := spec.load
			if transform == nil {
				full := spec.loadFull
				transform = func(ctx context.Context, dec *json.Decoder, _ pipeline.CopyUpsertSink, part string) error {
					return full(ctx, dec, sink, part)
				}
			}
			if err := transform(ctx, dec, sink, part); err != nil {
				failures = append(failures, _oops.With("spec_key", spec.key).With("part", part).Wrapf(err, "load dataset partition: transform"))
				stats.failed++
				continue
			}
			zap.S().Infow("success",
				"component", "load",
				"action", "transform",
				"event", "success",
				"dataset", spec.key,
				"partition", part,
			)
			stats.ok++
		}
		reportQuality(ctx, db, spec)
	}
	zap.S().Infow("done",
		"component", "load",
		"action", "run",
		"event", "done",
		"ok", stats.ok,
		"failed", stats.failed,
		"skipped", stats.skipped,
	)
	return stats, errors.Join(failures...)
}

func reportQuality(ctx context.Context, db *pgxpool.Pool, spec loadSpec) {
	for _, t := range spec.report {
		selects := []string{"COUNT(*) AS rows"}
		var cols []string
		for _, c := range t.textCols {
			selects = append(selects, fmt.Sprintf(
				"COUNT(*) FILTER (WHERE %q IS NULL OR %q = '') AS %s_empty", c, c, c))
			cols = append(cols, c)
		}
		for _, c := range t.geoCols {
			selects = append(selects, fmt.Sprintf(
				"COUNT(*) FILTER (WHERE %q IS NULL) AS %s_empty", c, c))
			cols = append(cols, c)
		}
		q := fmt.Sprintf("SELECT %s FROM %s", strings.Join(selects, ", "), t.table)
		vals := make([]int64, 1+len(cols))
		dest := make([]any, len(vals))
		for i := range vals {
			dest[i] = &vals[i]
		}
		if err := db.QueryRow(ctx, q).Scan(dest...); err != nil {
			zap.S().Errorw("query error",
				"component", "load",
				"action", "quality_report",
				"event", "query_error",
				"dataset", spec.key,
				"table", t.table,
				"err", err,
			)
			continue
		}
		rows := vals[0]
		// One field per column rather than a pre-rendered line, so the empty
		// ratios stay queryable per column in the log backend.
		ratios := make(map[string]float64, len(cols))
		for i, c := range cols {
			if rows > 0 {
				ratios[c] = float64(vals[i+1]) / float64(rows)
			}
		}
		zap.S().Infow("quality report",
			"component", "load",
			"action", "quality_report",
			"dataset", spec.key,
			"table", t.table,
			"rows", rows,
			"empty_ratios", ratios,
		)
	}
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

func (r rawTDXSource) readDatasetJSON(ctx context.Context, table, partCol, partVal string, includeCycle bool) ([]byte, time.Time, string, error) {
	target := raw.Target{Table: table, PartCol: partCol, PartVal: partVal}
	if err := raw.ValidateTarget(target); err != nil {
		return nil, time.Time{}, "", err
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.RepeatableRead,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		return nil, time.Time{}, "", _oops.With("table", table).With("part_val", partVal).Wrapf(err, "read raw dataset partition: begin")
	}
	defer func() {
		rbCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(rbCtx)
	}()

	var fetchedAt time.Time
	var expectedRows int64
	var landingCycle string
	stateSQL := `
		SELECT fetched_at, row_count
		FROM raw_tdx.landing_state
		WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3`
	if includeCycle {
		stateSQL = `
			SELECT fetched_at, row_count, COALESCE(landing_cycle, '')
			FROM raw_tdx.landing_state
			WHERE table_name=$1 AND partition_column=$2 AND partition_value=$3`
	}
	row := tx.QueryRow(ctx, stateSQL, table, partCol, partVal)
	if includeCycle {
		err = row.Scan(&fetchedAt, &expectedRows, &landingCycle)
	} else {
		err = row.Scan(&fetchedAt, &expectedRows)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return []byte("[]"), time.Time{}, "", nil
	}
	if err != nil {
		return nil, time.Time{}, "", _oops.With("table", table).With("part_val", partVal).Wrapf(err, "read raw dataset partition: landing state")
	}
	strip := "ARRAY['fetched_at']::text[]"
	if partCol != "" {
		strip = fmt.Sprintf("ARRAY['fetched_at','%s']::text[]", partCol)
	}
	elem := fmt.Sprintf("(to_jsonb(t) - %s)", strip)
	if table == "thsr_dailytimetable" {
		// Re-insert traindate as a YYYY-MM-DD string. When traindate is the
		// partition column it was stripped above; jsonb || sets it either way.
		elem = fmt.Sprintf("(%s || jsonb_build_object('traindate', to_char(t.traindate, 'YYYY-MM-DD')))", elem)
	}
	where := ""
	args := []any{}
	if partCol != "" {
		where = raw.PartitionWhere(target)
		args = append(args, partVal)
	}
	q := fmt.Sprintf(
		`SELECT %s::text FROM raw_tdx.%s t %s`,
		elem, table, where)
	rows, err := tx.Query(ctx, q, args...)
	if err != nil {
		return nil, time.Time{}, "", _oops.With("table", table).With("part_val", partVal).Wrapf(err, "read raw dataset partition: query rows")
	}
	defer rows.Close()
	var buf bytes.Buffer
	buf.WriteByte('[')
	var actualRows int64
	for rows.Next() {
		var rowJSON []byte
		if err := rows.Scan(&rowJSON); err != nil {
			return nil, time.Time{}, "", _oops.With("table", table).With("part_val", partVal).Wrapf(err, "read raw dataset partition: scan row")
		}
		if buf.Len() > 1 {
			buf.WriteByte(',')
		}
		buf.Write(rowJSON)
		actualRows++
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, "", _oops.With("table", table).With("part_val", partVal).Wrapf(err, "read raw dataset partition: rows")
	}
	if actualRows != expectedRows {
		return nil, time.Time{}, "", &raw.LandingStateMismatchError{
			Table: table, PartCol: partCol, PartVal: partVal,
			Reason: "loader_row_count", Expected: fmt.Sprint(expectedRows), Observed: fmt.Sprint(actualRows),
		}
	}
	buf.WriteByte(']')
	rows.Close()
	if err := tx.Commit(ctx); err != nil {
		return nil, time.Time{}, "", _oops.With("table", table).With("part_val", partVal).Wrapf(err, "read raw dataset partition: commit")
	}
	return buf.Bytes(), fetchedAt, landingCycle, nil
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
