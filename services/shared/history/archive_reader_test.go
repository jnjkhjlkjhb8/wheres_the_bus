package history

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

type archiveConnector struct{ conn *archiveTestConn }

func (c archiveConnector) Connect(context.Context) (driver.Conn, error) { return c.conn, nil }
func (c archiveConnector) Driver() driver.Driver                        { return archiveTestDriver{} }

type archiveTestDriver struct{}

func (archiveTestDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use connector") }

type archiveTestConn struct {
	columns  []string
	rows     [][]driver.Value
	queryErr error
	rowErr   error
	execErr  error
	query    string
	args     []driver.NamedValue
}

func (*archiveTestConn) Prepare(string) (driver.Stmt, error) { return nil, errors.New("not supported") }
func (*archiveTestConn) Close() error                        { return nil }
func (*archiveTestConn) Begin() (driver.Tx, error)           { return nil, errors.New("not supported") }
func (c *archiveTestConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.query, c.args = query, append([]driver.NamedValue(nil), args...)
	if c.queryErr != nil {
		return nil, c.queryErr
	}
	return &archiveTestRows{columns: c.columns, rows: c.rows, err: c.rowErr}, nil
}
func (c *archiveTestConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.query, c.args = query, append([]driver.NamedValue(nil), args...)
	return driver.RowsAffected(1), c.execErr
}

type archiveTestRows struct {
	columns []string
	rows    [][]driver.Value
	offset  int
	err     error
}

func (r *archiveTestRows) Columns() []string { return r.columns }
func (*archiveTestRows) Close() error        { return nil }
func (r *archiveTestRows) Next(dest []driver.Value) error {
	if r.offset == len(r.rows) {
		if r.err != nil {
			return r.err
		}
		return io.EOF
	}
	copy(dest, r.rows[r.offset])
	r.offset++
	return nil
}
func archiveReaderDB(t *testing.T, c *archiveTestConn) *sql.DB {
	t.Helper()
	db := sql.OpenDB(archiveConnector{conn: c})
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func TestArchiveReaderReturnsRowsAndUsesUTCWindow(t *testing.T) {
	local := time.Date(2026, 10, 9, 12, 30, 0, 0, time.FixedZone("UTC+8", 8*3600))
	c := &archiveTestConn{columns: []string{"sub", "direction", "stop", "recorded"}, rows: [][]driver.Value{{"route", int64(1), "stop", local.UTC()}}}
	m := mysqlHistory{db: archiveReaderDB(t, c)}
	got, err := m.arrivals(context.Background(), local)
	want := []arrivalEvent{{SubRouteUID: "route", Direction: 1, StopUID: "stop", arrivedAt: local.UTC()}}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("arrivals=%v, %v", got, err)
	}
	if len(c.args) != 1 || c.args[0].Value.(time.Time).Location() != time.UTC || !c.args[0].Value.(time.Time).Equal(local) {
		t.Fatalf("window=%v", c.args)
	}
	if !strings.Contains(c.query, "estimate <= 0") {
		t.Fatalf("query=%s", c.query)
	}
	c.columns = []string{"sub", "direction", "from", "to", "secs", "samples"}
	c.rows = [][]driver.Value{{"route", int64(0), "A", "B", int64(240), int64(9)}}
	segments, err := m.segmentsByEstimate(context.Background(), 3*time.Minute)
	if err != nil || !reflect.DeepEqual(segments, []SegmentObs{{SubRouteUID: "route", Direction: 0, fromStopUID: "A", toStopUID: "B", secs: 240, sampleCount: 9}}) {
		t.Fatalf("segments=%v, %v", segments, err)
	}
	if len(c.args) != 3 || c.args[0].Value != int64(180) || c.args[1].Value != int64(_segmentDiffMinSecs) || c.args[2].Value != int64(_segmentDiffMaxSecs) {
		t.Fatalf("segment bounds=%v", c.args)
	}
}

func TestArchiveReaderPropagatesQueryScanAndIterationFailures(t *testing.T) {
	sentinel := errors.New("archive unavailable")
	for _, kind := range []string{"arrivals", "segments", "partitions"} {
		t.Run(kind, func(t *testing.T) {
			c := &archiveTestConn{}
			switch kind {
			case "arrivals":
				c.columns = []string{"sub", "direction", "stop", "at"}
			case "segments":
				c.columns = []string{"sub", "direction", "from", "to", "secs", "samples"}
			case "partitions":
				c.columns = []string{"name", "bound"}
			}
			db := archiveReaderDB(t, c)
			call := func() error {
				switch kind {
				case "arrivals":
					_, err := (mysqlHistory{db: db}).arrivals(context.Background(), time.Now())
					return err
				case "segments":
					_, err := (mysqlHistory{db: db}).segmentsByEstimate(context.Background(), time.Hour)
					return err
				default:
					_, err := (mysqlArchiveAdmin{db: db}).partitions(context.Background(), "live_archive")
					return err
				}
			}
			c.queryErr = sentinel
			if err := call(); !errors.Is(err, sentinel) {
				t.Fatalf("query error=%v", err)
			}
			c.queryErr = nil
			c.rows = [][]driver.Value{make([]driver.Value, len(c.columns))}
			if err := call(); err == nil || !strings.Contains(err.Error(), "scan") {
				t.Fatalf("scan error=%v", err)
			}
			c.rows = nil
			c.rowErr = sentinel
			if err := call(); !errors.Is(err, sentinel) {
				t.Fatalf("iteration error=%v", err)
			}
		})
	}
}

func TestArchivePartitionReaderSkipsMaxAndDecodesDays(t *testing.T) {
	upper := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	c := &archiveTestConn{columns: []string{"name", "bound"}, rows: [][]driver.Value{{"p2026_10", " " + strconv.Itoa(toMySQLDays(upper)) + " "}, {"p_max", " mAxVaLuE "}}}
	admin := mysqlArchiveAdmin{db: archiveReaderDB(t, c)}
	got, err := admin.partitions(context.Background(), "live_archive_bus")
	if err != nil || !reflect.DeepEqual(got, []archivePartition{{name: "p2026_10", upper: upper}}) {
		t.Fatalf("partitions=%v %v", got, err)
	}
	if len(c.args) != 1 || c.args[0].Value != "live_archive_bus" {
		t.Fatalf("table=%v", c.args)
	}
	c.rows = [][]driver.Value{{"bad", "not a number"}}
	if _, err := admin.partitions(context.Background(), "live_archive_bus"); err == nil || !strings.Contains(err.Error(), "parse partition bound") {
		t.Fatalf("parse error=%v", err)
	}
	if _, err := admin.ExecContext(context.Background(), "ALTER TABLE x", 3); err != nil || c.query != "ALTER TABLE x" || c.args[0].Value != int64(3) {
		t.Fatalf("exec=%v %v", c.args, err)
	}
}

func TestArchiveInitDisabledAndRejectsInvalidConnections(t *testing.T) {
	saved := _archive
	t.Cleanup(func() { _archive = saved })
	closer, err := Init(context.Background(), " \t\n")
	if err != nil || closer == nil || closer() != nil || _archive != nil || Target() != nil || ResolveSource() != nil || AdminTarget() != nil {
		t.Fatalf("disabled archive=%v", err)
	}
	if err := (*archiver)(nil).Close(); err != nil {
		t.Fatalf("nil close=%v", err)
	}
	for _, dsn := range []string{"user@tcp(localhost:3306)/history", "invalid?parseTime=true", "user@tcp(127.0.0.1:1)/history?parseTime=true&timeout=1ms"} {
		if closer, err := Init(context.Background(), dsn); err == nil || closer != nil {
			t.Fatalf("invalid connection returned closer=%v err=%v", closer != nil, err)
		}
	}
	c := &archiveTestConn{}
	a := &archiver{db: archiveReaderDB(t, c)}
	_archive = a
	if Target() != a.db || ResolveSource() == nil || AdminTarget() == nil {
		t.Fatal("enabled archive views missing")
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
}
