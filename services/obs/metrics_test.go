package obs

import (
	"errors"
	"strings"
	"testing"
)

func TestRecordGRPCRequestCountsRequestsAndErrors(t *testing.T) {
	resetMetricsForTest()
	RecordGRPCRequest("/pb.Bus_Route_Service/Static", nil)
	RecordGRPCRequest("/pb.Bus_Route_Service/Static", nil)
	RecordGRPCRequest("/pb.Bus_Route_Service/Static", errors.New("boom"))

	text := MetricsText()
	assertLine(t, text, `router_grpc_requests_total{method="/pb.Bus_Route_Service/Static"} 3`)
	assertLine(t, text, `router_grpc_errors_total{method="/pb.Bus_Route_Service/Static"} 1`)
}

func TestRecordHTTPRequestCounts5xxAsErrorNot4xx(t *testing.T) {
	resetMetricsForTest()
	RecordHTTPRequest("/api/search", 200)
	RecordHTTPRequest("/api/search", 400)
	RecordHTTPRequest("/api/search", 500)

	text := MetricsText()
	assertLine(t, text, `router_http_requests_total{path="/api/search"} 3`)
	assertLine(t, text, `router_http_errors_total{path="/api/search"} 1`)
}

func TestIncCountersAreIndependentAndCumulative(t *testing.T) {
	resetMetricsForTest()
	IncStreamDisconnect()
	IncStreamDisconnect()
	IncRedisError()
	IncDBError()
	IncDBError()
	IncDBError()

	text := MetricsText()
	assertLine(t, text, "router_stream_disconnects_total 2")
	assertLine(t, text, "router_redis_errors_total 1")
	assertLine(t, text, "router_db_errors_total 3")
}

func assertLine(t *testing.T, text, want string) {
	t.Helper()
	for _, line := range strings.Split(text, "\n") {
		if line == want {
			return
		}
	}
	t.Fatalf("metrics text missing line %q, got:\n%s", want, text)
}
