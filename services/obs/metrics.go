package obs

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

type methodCounter struct {
	requests atomic.Int64
	errors   atomic.Int64
}

// counterSet is a label -> *methodCounter registry. The zero value is ready
// to use; entries are created lazily on first observation and never removed,
// which is safe because the label set is bounded (see methodCounter).
type counterSet struct {
	entries sync.Map // map[string]*methodCounter
}

func (s *counterSet) record(label string, failed bool) {
	v, ok := s.entries.Load(label)
	if !ok {
		v, _ = s.entries.LoadOrStore(label, &methodCounter{})
	}
	c, ok := v.(*methodCounter)
	if !ok {
		return
	}
	c.requests.Add(1)
	if failed {
		c.errors.Add(1)
	}
}

// counterRow is one label's request/error totals at snapshot time.
type counterRow struct {
	label           string
	requests, fails int64
}

// snapshot returns label -> (requests, errors) sorted by label so repeated
// calls (and the resulting metrics text) are deterministic.
func (s *counterSet) snapshot() []counterRow {
	var rows []counterRow
	s.entries.Range(func(k, v any) bool {
		c, ok := v.(*methodCounter)
		if !ok {
			return true
		}
		label, ok := k.(string)
		if !ok {
			return true
		}
		rows = append(rows, counterRow{label, c.requests.Load(), c.errors.Load()})
		return true
	})
	sort.Slice(rows, func(i, j int) bool { return rows[i].label < rows[j].label })
	return rows
}

var (
	_grpcCounters           counterSet
	_httpCounters           counterSet
	_streamDisconnectsTotal atomic.Int64
	_redisErrorsTotal       atomic.Int64
	_dbErrorsTotal          atomic.Int64
)

func RecordGRPCRequest(fullMethod string, err error) {
	_grpcCounters.record(fullMethod, err != nil)
}

// RecordHTTPRequest tallies one completed HTTP request under path, counting
// it as an error when status is >= 500 (a server-side failure; 4xx client
// errors are not infrastructure health signals).
func RecordHTTPRequest(path string, status int) {
	_httpCounters.record(path, status >= 500)
}

func IncStreamDisconnect() {
	_streamDisconnectsTotal.Add(1)
}

// IncRedisError counts one failed Redis operation on the live-stream hot
// path (get, scan, subscribe). Unlabeled for the same cardinality reason as
// IncStreamDisconnect.
func IncRedisError() {
	_redisErrorsTotal.Add(1)
}

// IncDBError counts one PostgreSQL query failure that is not a plain
// not-found result (see grpcStatusFor in services/api/main.go, the sole
// caller): a missing row is expected traffic, not a database health signal.
func IncDBError() {
	_dbErrorsTotal.Add(1)
}

func MetricsText() string {
	var b strings.Builder
	writeLabeled(&b, "router_grpc_requests_total", "router_grpc_errors_total", "method", _grpcCounters.snapshot())
	writeLabeled(&b, "router_http_requests_total", "router_http_errors_total", "path", _httpCounters.snapshot())
	fmt.Fprintf(&b, "router_stream_disconnects_total %d\n", _streamDisconnectsTotal.Load())
	fmt.Fprintf(&b, "router_redis_errors_total %d\n", _redisErrorsTotal.Load())
	fmt.Fprintf(&b, "router_db_errors_total %d\n", _dbErrorsTotal.Load())
	return b.String()
}

func writeLabeled(b *strings.Builder, requestsName, errorsName, labelName string, rows []counterRow) {
	for _, row := range rows {
		fmt.Fprintf(b, "%s{%s=%q} %d\n", requestsName, labelName, row.label, row.requests)
		fmt.Fprintf(b, "%s{%s=%q} %d\n", errorsName, labelName, row.label, row.fails)
	}
}

// resetMetricsForTest clears every counter. Test-only (unexported); package
// obs has no exported reset because production code never needs one -- the
// process lifetime is the only scope that matters outside tests.
func resetMetricsForTest() {
	_grpcCounters = counterSet{}
	_httpCounters = counterSet{}
	_streamDisconnectsTotal.Store(0)
	_redisErrorsTotal.Store(0)
	_dbErrorsTotal.Store(0)
}
