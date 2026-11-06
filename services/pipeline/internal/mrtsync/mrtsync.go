// Package mrtsync copies the tables PowerSync serves from the bus database to
// powersync-db, so PowerSync's REPLICATION login never touches the main
// cluster (ADR-0028).
package mrtsync

import (
	"context"
	_ "embed"
	"fmt"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
	"go.uber.org/zap"
)

//go:embed schema.sql
var schemaSQL string

// Source reads the bus tables; *pgxpool.Pool satisfies it.
type Source interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

type table struct {
	name string
	key  []string
	data []string
	// derived maps a copy column to the bus expression that produces it, for
	// columns the bus table does not hold under that name.
	derived map[string]string
	// read replaces the SQL copy for a table built in Go from bus data, with
	// rows in columns() order. Such a table has no bus counterpart.
	read func(ctx context.Context, src Source) ([][]any, error)
}

func (t table) columns() []string { return append(append([]string{}, t.key...), t.data...) }

// readRows reads the copy's rows from bus, in columns() order.
func (t table) readRows(ctx context.Context, src Source) ([][]any, error) {
	if t.read != nil {
		return t.read(ctx, src)
	}
	return readSource(ctx, src, t)
}

// selectList reads every copy column from bus, deriving the ones in derived.
func (t table) selectList() string {
	cols := t.columns()
	for i, c := range cols {
		if expr, ok := t.derived[c]; ok {
			cols[i] = expr + " AS " + c
		}
	}
	return strings.Join(cols, ", ")
}

var _tables = []table{
	{
		name: "mrt_schedule",
		key:  []string{"system", "station_id", "lineid", "destinationstaionid", "serviceday"},
		data: []string{"firsttraintime", "lasttraintime"},
	},
	{
		name: "mrt_journey_matrix",
		key:  []string{"id"},
		data: []string{"from_station_id", "to_station_id", "system", "fare_nt", "half_fare_nt", "travel_time_min"},
	},
	{
		// Offline search (ADR-0003). PowerSync columns are text, integer or
		// real, so the point travels as lat/lon; updated_at stays behind so a
		// nightly rebuild that changes nothing streams nothing.
		name:    "search_vector",
		key:     []string{"type", "uid", "city"},
		data:    []string{"name", "alias", "depart", "destin", "lat", "lon"},
		derived: map[string]string{"lat": "ST_Y(geom)", "lon": "ST_X(geom)"},
	},
	_busRouteOffline,
}

// Stats counts what one table's sync changed.
type Stats struct {
	Table             string
	Source            int
	Upserted, Deleted int64
}

// Run connects to powersync-db at dsn, syncs and logs what changed.
func Run(ctx context.Context, src Source, dsn string) error {
	dst, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return _oops.Wrapf(err, "connect powersync-db")
	}
	defer func() { _ = dst.Close(context.Background()) }()
	stats, err := Sync(ctx, src, dst)
	for _, s := range stats {
		zap.S().Infow("synced", "component", "pipeline", "action", "mrt_sync", "event", "synced",
			"table", s.Table, "source_rows", s.Source, "upserted", s.Upserted, "deleted", s.Deleted)
	}
	return err
}

// Sync applies the schema, then brings every copy in line with bus inside one
// transaction. Unchanged rows are not rewritten, so PowerSync only streams real
// changes to clients.
func Sync(ctx context.Context, src Source, dst *pgx.Conn) ([]Stats, error) {
	if err := prepare(ctx, dst); err != nil {
		return nil, err
	}
	snapshots, err := readSources(ctx, src)
	if err != nil {
		return nil, err
	}
	return mergeAll(ctx, dst, snapshots)
}

func prepare(ctx context.Context, dst *pgx.Conn) error {
	if _, err := dst.Exec(ctx, schemaSQL); err != nil {
		return _oops.Wrapf(err, "apply schema")
	}
	return checkColumns(ctx, dst)
}

func readSources(ctx context.Context, src Source) ([][][]any, error) {
	snapshots := make([][][]any, len(_tables))
	for i, t := range _tables {
		rows, err := readNonEmpty(ctx, src, t)
		if err != nil {
			return nil, err
		}
		snapshots[i] = rows
	}
	return snapshots, nil
}

// readNonEmpty refuses an empty source: it means the load failed, not that
// every train vanished, and syncing it would wipe the table from every client.
func readNonEmpty(ctx context.Context, src Source, t table) ([][]any, error) {
	rows, err := t.readRows(ctx, src)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, _oops.With("table", t.name).Errorf("source table is empty")
	}
	return rows, nil
}

func mergeAll(ctx context.Context, dst *pgx.Conn, snapshots [][][]any) ([]Stats, error) {
	var stats []Stats
	err := pgx.BeginFunc(ctx, dst, func(tx pgx.Tx) error {
		var err error
		stats, err = mergeTables(ctx, tx, snapshots)
		return err
	})
	if err != nil {
		return nil, err
	}
	return stats, nil
}

func mergeTables(ctx context.Context, tx pgx.Tx, snapshots [][][]any) ([]Stats, error) {
	stats := make([]Stats, 0, len(_tables))
	for i, t := range _tables {
		s, err := merge(ctx, tx, t, snapshots[i])
		if err != nil {
			return nil, err
		}
		stats = append(stats, s)
	}
	return stats, nil
}

// checkColumns fails when a copy's live columns differ from what the sync
// writes. CREATE TABLE IF NOT EXISTS leaves an existing table as it is, so a
// column added to schema.sql without its own ALTER TABLE line lands here
// instead of as an opaque COPY error.
func checkColumns(ctx context.Context, dst *pgx.Conn) error {
	for _, t := range _tables {
		if err := checkTableColumns(ctx, dst, t); err != nil {
			return err
		}
	}
	return nil
}

func checkTableColumns(ctx context.Context, dst *pgx.Conn, t table) error {
	live, err := liveColumns(ctx, dst, t.name)
	if err != nil {
		return err
	}
	want := t.columns()
	slices.Sort(want)
	if !slices.Equal(live, want) {
		return _oops.With("table", t.name, "live", live, "want", want).Errorf("copy columns differ from schema.sql; add an ALTER TABLE line there")
	}
	return nil
}

func liveColumns(ctx context.Context, dst *pgx.Conn, table string) ([]string, error) {
	rows, err := dst.Query(ctx, `SELECT column_name::text FROM information_schema.columns
		WHERE table_schema = current_schema() AND table_name = $1 ORDER BY 1`, table)
	if err != nil {
		return nil, _oops.With("table", table).Wrapf(err, "read live columns")
	}
	cols, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, _oops.With("table", table).Wrapf(err, "scan live columns")
	}
	return cols, nil
}

func readSource(ctx context.Context, src Source, t table) ([][]any, error) {
	key := strings.Join(t.key, ", ")
	// DISTINCT ON keeps the copy's primary key satisfiable even if bus ever
	// holds two rows for one key; the newest wins.
	query := fmt.Sprintf(`SELECT DISTINCT ON (%s) %s FROM %s ORDER BY %s, updated_at DESC NULLS LAST`,
		key, t.selectList(), t.name, key)
	rows, err := src.Query(ctx, query)
	if err != nil {
		return nil, _oops.With("table", t.name).Wrapf(err, "read source")
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) ([]any, error) { return r.Values() })
	if err != nil {
		return nil, _oops.With("table", t.name).Wrapf(err, "scan source")
	}
	return out, nil
}

func merge(ctx context.Context, tx pgx.Tx, t table, rows [][]any) (Stats, error) {
	stage := "stage_" + t.name
	if _, err := tx.Exec(ctx, fmt.Sprintf(`CREATE TEMP TABLE %s (LIKE %s) ON COMMIT DROP`, stage, t.name)); err != nil {
		return Stats{}, _oops.With("table", t.name).Wrapf(err, "create stage")
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{stage}, t.columns(), pgx.CopyFromRows(rows)); err != nil {
		return Stats{}, _oops.With("table", t.name).Wrapf(err, "copy stage")
	}
	return applyStage(ctx, tx, t, stage, len(rows))
}

// applyStage makes the copy equal to the staged rows.
func applyStage(ctx context.Context, tx pgx.Tx, t table, stage string, source int) (Stats, error) {
	upserted, err := tx.Exec(ctx, upsertSQL(t, stage))
	if err != nil {
		return Stats{}, _oops.With("table", t.name).Wrapf(err, "upsert")
	}
	deleted, err := tx.Exec(ctx, deleteSQL(t, stage))
	if err != nil {
		return Stats{}, _oops.With("table", t.name).Wrapf(err, "delete")
	}
	return Stats{Table: t.name, Source: source, Upserted: upserted.RowsAffected(), Deleted: deleted.RowsAffected()}, nil
}

func upsertSQL(t table, stage string) string {
	cols := strings.Join(t.columns(), ", ")
	set := make([]string, len(t.data))
	old := make([]string, len(t.data))
	incoming := make([]string, len(t.data))
	for i, c := range t.data {
		set[i] = c + " = EXCLUDED." + c
		old[i] = t.name + "." + c
		incoming[i] = "EXCLUDED." + c
	}
	return fmt.Sprintf(`INSERT INTO %s (%s) SELECT %s FROM %s
ON CONFLICT (%s) DO UPDATE SET %s
WHERE (%s) IS DISTINCT FROM (%s)`,
		t.name, cols, cols, stage,
		strings.Join(t.key, ", "), strings.Join(set, ", "),
		strings.Join(old, ", "), strings.Join(incoming, ", "))
}

func deleteSQL(t table, stage string) string {
	match := make([]string, len(t.key))
	for i, c := range t.key {
		match[i] = fmt.Sprintf("s.%s = %s.%s", c, t.name, c)
	}
	return fmt.Sprintf(`DELETE FROM %s WHERE NOT EXISTS (SELECT 1 FROM %s s WHERE %s)`,
		t.name, stage, strings.Join(match, " AND "))
}
