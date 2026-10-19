package obs

import (
	"errors"
	"testing"

	"github.com/getsentry/sentry-go"
	"github.com/samber/oops"
	"go.uber.org/zap"
)

func TestOopsScopePreservesStructuredAttributes(t *testing.T) {
	structured := oops.In("worker").Code("decode").Tags("tdx").With("city", "Taipei").With("rows", 3).Wrapf(errors.New("bad payload"), "parse")
	scope := sentry.NewScope()
	applyOopsScope(scope, structured)
	event := sentry.NewEvent()
	scope.ApplyToEvent(event, nil, nil)
	if event.Tags["err.domain"] != "worker" || event.Tags["err.code"] != "decode" || event.Tags["err.tag.tdx"] != "true" {
		t.Fatalf("tags=%v", event.Tags)
	}
	block := event.Contexts["error attributes"]
	if block["city"] != "Taipei" || block["rows"] != 3 {
		t.Fatalf("attributes=%v", block)
	}
	if event.Contexts["error stacktrace"]["frames"] == nil {
		t.Fatal("stacktrace missing")
	}
	for _, err := range []error{nil, errors.New("plain"), oops.Errorf("unclassified")} {
		scope := sentry.NewScope()
		applyOopsScope(scope, err)
		e := sentry.NewEvent()
		scope.ApplyToEvent(e, nil, nil)
		if len(e.Tags) != 0 {
			t.Fatalf("plain tags=%v", e.Tags)
		}
	}
	_, tr := newTestLogger(t)
	Capture("decode", structured)
	if len(tr.events) != 1 || tr.events[0].Tags["err.domain"] != "worker" || tr.events[0].Contexts["error attributes"]["city"] != "Taipei" {
		t.Fatalf("captured scope=%v", tr.events)
	}
}

func TestObsInitConfiguresServiceAndTraceRate(t *testing.T) {
	hub := sentry.CurrentHub()
	client := hub.Client()
	hub.PushScope()
	logger := zap.L()
	t.Cleanup(func() {
		hub.BindClient(client)
		hub.PopScope()
		zap.ReplaceGlobals(logger)
	})
	t.Setenv("SENTRY_DSN", "")
	Init("disabled")()
	t.Setenv("SENTRY_DSN", "invalid")
	Init("invalid")()
	for _, tc := range []struct {
		rate string
		want float64
	}{{"", 0.1}, {"bad", 0.1}, {"0", 0}, {"0.25", 0.25}} {
		t.Setenv("SENTRY_DSN", "http://test@127.0.0.1:1/1")
		t.Setenv("SENTRY_ENVIRONMENT", "quality")
		t.Setenv("SENTRY_TRACES_SAMPLE_RATE", tc.rate)
		shutdown := Init("rider")
		current := sentry.CurrentHub().Client()
		if current == nil {
			t.Fatal("client missing")
		}
		opts := current.Options()
		if opts.ServerName != "rider" || opts.Environment != "quality" || opts.TracesSampleRate != tc.want || opts.EnableTracing != (tc.want > 0) {
			t.Fatalf("options=%+v", opts)
		}
		e := sentry.NewEvent()
		sentry.CurrentHub().Scope().ApplyToEvent(e, nil, nil)
		if e.Tags["service"] != "rider" {
			t.Fatalf("service tags=%v", e.Tags)
		}
		shutdown()
		current.Close()
	}
}
