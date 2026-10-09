package history

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"go.uber.org/zap"
)

type archiver struct {
	db *sql.DB
}

var _archive *archiver

const RowsPerInsert = 1000

// Execer is the write seam. *sql.DB satisfies it; tests substitute a
// recorder to assert batching without a live MySQL.
type Execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

type SegmentObs struct {
	SubRouteUID string
	Direction   int16
	fromStopUID string
	toStopUID   string
	secs        int
	sampleCount int
}

type Reader interface {
	arrivals(ctx context.Context, since time.Time) ([]arrivalEvent, error)
	segmentsByEstimate(ctx context.Context, window time.Duration) ([]SegmentObs, error)
}

type mysqlHistory struct{ db *sql.DB }

const _segmentMedianTail = `
	), ranked AS (
		SELECT sub_route_uid, direction, from_stop_uid, to_stop_uid, secs,
		       ROW_NUMBER() OVER gs AS rn,
		       COUNT(*)     OVER g  AS n
		FROM kept
		WINDOW g  AS (PARTITION BY sub_route_uid, direction, from_stop_uid, to_stop_uid),
		       gs AS (g ORDER BY secs)
	)
	SELECT sub_route_uid, direction, from_stop_uid, to_stop_uid,
	       CAST(ROUND(AVG(secs)) AS SIGNED), MAX(n)
	FROM ranked
	WHERE rn IN (FLOOR((n + 1) / 2), CEILING((n + 1) / 2))
	GROUP BY sub_route_uid, direction, from_stop_uid, to_stop_uid`

func (m mysqlHistory) segmentsByEstimate(ctx context.Context, window time.Duration) ([]SegmentObs, error) {
	rows, err := m.db.QueryContext(ctx, `
		WITH kept AS (
			SELECT sub_route_uid, direction, stop_uid AS from_stop_uid,
			       next_stop_uid AS to_stop_uid, next_estimate - estimate AS secs
			FROM (
				-- One snapshot of one subroute, read along the stop sequence. The
				-- partition is the instant itself: every row in it was written by
				-- the same pass over the same TDX response.
				SELECT sub_route_uid, direction, stop_uid, stop_sequence, estimate,
				       LEAD(stop_uid)      OVER w AS next_stop_uid,
				       LEAD(stop_sequence) OVER w AS next_stop_sequence,
				       LEAD(estimate)      OVER w AS next_estimate
				FROM bus_eta_history
				WHERE recorded_at >= UTC_TIMESTAMP() - INTERVAL ? SECOND
				WINDOW w AS (PARTITION BY sub_route_uid, direction, recorded_at
				             ORDER BY stop_sequence)
			) ordered
			WHERE next_stop_uid IS NOT NULL
			  -- Adjacent stops only, matching segmentsByPlate: a gap would record
			  -- several hops' running time as one.
			  AND next_stop_sequence = stop_sequence + 1
			  AND next_estimate - estimate BETWEEN ? AND ?`+_segmentMedianTail,
		int64(window.Seconds()), _segmentDiffMinSecs, _segmentDiffMaxSecs)
	if err != nil {
		return nil, _oops.Wrapf(err, "query estimate segments")
	}
	return scanSegmentObs(rows)
}

func scanSegmentObs(rows *sql.Rows) ([]SegmentObs, error) {
	defer func() { _ = rows.Close() }()
	var out []SegmentObs
	for rows.Next() {
		var s SegmentObs
		if err := rows.Scan(&s.SubRouteUID, &s.Direction, &s.fromStopUID,
			&s.toStopUID, &s.secs, &s.sampleCount); err != nil {
			return nil, _oops.Wrapf(err, "scan segment observation")
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// arrivals returns observed arrivals — history rows whose estimate reached zero
// — since an instant, for matching against open predictions.
func (m mysqlHistory) arrivals(ctx context.Context, since time.Time) ([]arrivalEvent, error) {
	rows, err := m.db.QueryContext(ctx, `
		SELECT sub_route_uid, direction, stop_uid, recorded_at
		FROM bus_eta_history
		WHERE estimate <= 0 AND recorded_at >= ?`, since.UTC())
	if err != nil {
		return nil, _oops.Wrapf(err, "query arrivals")
	}
	defer func() { _ = rows.Close() }()
	var out []arrivalEvent
	for rows.Next() {
		var a arrivalEvent
		if err := rows.Scan(&a.SubRouteUID, &a.Direction, &a.StopUID, &a.arrivedAt); err != nil {
			return nil, _oops.Wrapf(err, "scan arrival")
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func Init(ctx context.Context, dsn string) (func() error, error) {
	if strings.TrimSpace(dsn) == "" {
		zap.S().Infow("disabled", "component", "archive", "event", "disabled", "reason", "empty_dsn")
		_archive = nil
		return func() error { return nil }, nil
	}
	// Without parseTime the driver hands DATETIME back as []byte and every
	// history read fails at scan time — at 04:00, in a cron, a day after the
	// deploy. Refuse at startup instead.
	if !strings.Contains(dsn, "parseTime=true") {
		return nil, errors.New("archive DSN must set parseTime=true (DATETIME columns are scanned into time.Time)")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, _oops.Wrapf(err, "open archive")
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(time.Hour)
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		return nil, _oops.Wrapf(errors.Join(err, db.Close()), "ping archive")
	}
	zap.S().Infow("ready", "component", "archive", "event", "ready")
	_archive = &archiver{db: db}
	return _archive.Close, nil
}

// Close closes the pool, or is a no-op on a disabled (nil) archiver.
func (a *archiver) Close() error {
	if a == nil {
		return nil
	}
	return a.db.Close()
}

func (a *archiver) target() Execer {
	if a == nil {
		return nil
	}
	return a.db
}

func (a *archiver) history() Reader {
	if a == nil {
		return nil
	}
	return mysqlHistory{db: a.db}
}

// Target and archiveHistory expose the process-wide archiver to this
// package's free-function call sites (cron jobs registered in main.go).
func Target() Execer {
	return _archive.target()
}

func archiveHistory() Reader {
	return _archive.history()
}

func ResolveSource() Reader {
	h := archiveHistory()
	if h == nil {
		zap.S().Warnw("log",
			"component", "history",
			"action", "resolve",
			"source", "none",
			"reason", "archive_disabled",
		)
		return nil
	}
	zap.S().Infow("log", "component", "history", "action", "resolve", "source", "mysql")
	return h
}

// archiveInsertSQL builds the multi-row INSERT IGNORE for n rows of cols.
// table and cols come from package-level constants only, never external input.
func archiveInsertSQL(table string, cols []string, n int) string {
	one := "(" + strings.TrimSuffix(strings.Repeat("?,", len(cols)), ",") + ")"
	return "INSERT IGNORE INTO " + table + " (" + strings.Join(cols, ",") + ") VALUES " +
		strings.TrimSuffix(strings.Repeat(one+",", n), ",")
}

func Insert(ctx context.Context, db Execer, table string, cols []string, rows [][]any) error {
	if db == nil || len(rows) == 0 {
		return nil
	}
	for start := 0; start < len(rows); start += RowsPerInsert {
		end := min(start+RowsPerInsert, len(rows))
		batch := rows[start:end]
		args := make([]any, 0, len(batch)*len(cols))
		for _, r := range batch {
			if len(r) != len(cols) {
				return _oops.With("table", table).With("values", len(r)).With("cols", len(cols)).Errorf("row width does not match column count")
			}
			args = append(args, archiveUTC(r)...)
		}
		if _, err := db.ExecContext(ctx, archiveInsertSQL(table, cols, len(batch)), args...); err != nil {
			return _oops.With("table", table).With("start", start).With("end", end).Wrapf(err, "archive rows ..")
		}
	}
	return nil
}

// archiveUTC normalizes every timestamp in a row to UTC. MySQL DATETIME carries
// no zone, so the conversion happens before the value leaves Go rather than
// being left to whatever `loc` the DSN happens to set.
func archiveUTC(vals []any) []any {
	for i, v := range vals {
		if t, ok := v.(time.Time); ok {
			vals[i] = t.UTC()
		}
	}
	return vals
}
