package raw

import (
	"bytes"
	"compress/gzip"
	"context"
	"database/sql"
	"errors"
	"io"
	"strings"
	"testing"
)

// The archived payload must be byte-identical to what upstream served, and the
// reader must come back rewound: the landing that follows reads the same body,
// and a reader left at EOF would land an empty array over live data.
func TestArchiveRawPayloadStoresPayloadVerbatimAndRewinds(t *testing.T) {
	const body = `[{"RouteUID":"TPE10132","UpdateTime":"2026-08-21T03:00:00+08:00"}]`
	f := &fakeExecer{}
	r := bytes.NewReader([]byte(body))

	ArchivePayload(context.Background(), f, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"},
		"Thu, 21 Aug 2026 03:00:00 GMT", "2026-08-21", r)

	if len(f.stmts) != 1 {
		t.Fatalf("want one INSERT, got %d", len(f.stmts))
	}
	if !strings.Contains(f.stmts[0], "INSERT IGNORE INTO raw_tdx_archive") {
		t.Errorf("want an INSERT IGNORE so uq_version absorbs a refetch, got %q", f.stmts[0])
	}
	args := f.args[0]
	if len(args) != len(_rawArchiveCols) {
		t.Fatalf("want %d bound values, got %d", len(_rawArchiveCols), len(args))
	}
	if args[0] != "bus_route" || args[1] != "Taipei" {
		t.Errorf("want dataset/partition bus_route/Taipei, got %v/%v", args[0], args[1])
	}
	payload, ok := args[5].([]byte)
	if !ok {
		t.Fatalf("want a gzipped []byte payload, got %T", args[5])
	}
	if got := gunzip(t, payload); got != body {
		t.Errorf("payload is not verbatim:\n got %q\nwant %q", got, body)
	}
	rest, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read body after archiving: %v", err)
	}
	if string(rest) != body {
		t.Errorf("body was left consumed; the landing would see %q", rest)
	}
}

func TestArchiveRawPayloadSwallowsWriteFailure(t *testing.T) {
	f := &fakeExecer{err: errors.New("archive host down")}
	ArchivePayload(context.Background(), f, Target{Table: "bus_route"}, "marker", "cycle",
		bytes.NewReader([]byte("[]")))
}

// ARCHIVE_MYSQL_DSN is empty everywhere but prod, so the nil target is the
// normal case, not an error case.
func TestArchiveRawPayloadNoTargetIsNoOp(t *testing.T) {
	ArchivePayload(context.Background(), nil, Target{Table: "bus_route"}, "marker", "cycle",
		bytes.NewReader([]byte("[]")))
}

func gunzip(t *testing.T, b []byte) string {
	t.Helper()
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatalf("open gzip stream: %v", err)
	}
	defer func() { _ = zr.Close() }()
	out, err := io.ReadAll(zr)
	if err != nil {
		t.Fatalf("read gzip stream: %v", err)
	}
	return string(out)
}

// Archive execer fake. The history package keeps its own copy for the insert
// path; this one drives the raw-payload archive wrapper.

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
