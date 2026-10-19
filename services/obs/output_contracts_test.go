package obs

import (
	"errors"
	"strings"
	"testing"

	"github.com/getsentry/sentry-go"
	"github.com/samber/oops"
)

func TestMetricsExpositionHasStableLabelOrder(t *testing.T) {
	resetMetricsForTest()
	t.Cleanup(resetMetricsForTest)
	for _, name := range []string{"Z", "A", "M"} {
		RecordGRPCRequest("/pb."+name+"/Read", nil)
		RecordHTTPRequest("/api/"+name, 200)
	}
	RecordGRPCRequest("/pb.A/Read", errors.New("bad request"))
	RecordHTTPRequest("/api/A", 503)
	text := MetricsText()
	for _, prefix := range []string{
		`router_grpc_requests_total{method="/pb.`,
		`router_http_requests_total{path="/api/`,
	} {
		a := strings.Index(text, prefix+"A")
		m := strings.Index(text, prefix+"M")
		z := strings.Index(text, prefix+"Z")
		if a < 0 || m <= a || z <= m {
			t.Fatalf("metric labels are not A, M, Z for %q:\n%s", prefix, text)
		}
	}
	assertLine(t, text, `router_grpc_requests_total{method="/pb.A/Read"} 2`)
	assertLine(t, text, `router_grpc_errors_total{method="/pb.A/Read"} 1`)
	assertLine(t, text, `router_http_requests_total{path="/api/A"} 2`)
	assertLine(t, text, `router_http_errors_total{path="/api/A"} 1`)
}

func TestStructuredErrorsKeepAbsentTagsAndAttributesAbsent(t *testing.T) {
	transport := &fakeTransport{}
	client, err := sentry.NewClient(sentry.ClientOptions{
		Dsn:       "https://fixture@example.invalid/1",
		Transport: transport,
	})
	if err != nil {
		t.Fatal(err)
	}
	hub := sentry.CurrentHub()
	previous := hub.Client()
	hub.PushScope()
	hub.Scope().Clear()
	hub.BindClient(client)
	t.Cleanup(func() {
		hub.BindClient(previous)
		hub.PopScope()
		client.Close()
	})
	structured := oops.In("worker").Code("decode").Errorf("invalid payload")
	line := logLine(t, structured)
	if _, present := line["err.tags"]; present {
		t.Fatalf("untagged structured error added err.tags: %v", line)
	}
	if line["err.domain"] != "worker" || line["err.code"] != "decode" {
		t.Fatalf("structured classification disappeared from JSON: %v", line)
	}
	Capture("decode", structured)
	if len(transport.events) != 2 {
		t.Fatalf("captured events = %d, want logger and explicit capture", len(transport.events))
	}
	captured := transport.events[1]
	if captured.Tags["job"] != "decode" || captured.Tags["err.domain"] != "worker" || captured.Tags["err.code"] != "decode" {
		t.Fatalf("structured classification disappeared from explicit capture: %v", captured.Tags)
	}
	for _, event := range transport.events {
		if _, present := event.Contexts["error attributes"]; present {
			t.Fatalf("attribute-free structured error added error attributes: %v", event.Contexts)
		}
	}
}
