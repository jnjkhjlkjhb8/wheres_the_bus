package obs

import (
	"context"
	"errors"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"
	"github.com/samber/oops"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

type fakeTransport struct{ events []*sentry.Event }

func (t *fakeTransport) Configure(sentry.ClientOptions) {}
func (t *fakeTransport) SendEvent(e *sentry.Event)      { t.events = append(t.events, e) }
func (t *fakeTransport) Flush(time.Duration) bool       { return true }
func (t *fakeTransport) FlushWithContext(context.Context) bool {
	return true
}
func (t *fakeTransport) Close() {}

func newTestLogger(t *testing.T) (*zap.SugaredLogger, *fakeTransport) {
	t.Helper()
	tr := &fakeTransport{}
	err := sentry.Init(sentry.ClientOptions{
		Dsn:       "https://key@example.com/1",
		Transport: tr,
	})
	if err != nil {
		t.Fatal(err)
	}
	core := zapcore.NewCore(zapcore.NewJSONEncoder(zap.NewProductionEncoderConfig()), zapcore.Lock(os.Stderr), zapcore.InfoLevel)
	return zap.New(NewCore(core)).Sugar(), tr
}

func TestCoreErrorGoesToSentry(t *testing.T) {
	logger, tr := newTestLogger(t)
	logger.Errorw("ingest failed", "action", "busStatic", "err", errors.New("boom"))
	if len(tr.events) != 1 {
		t.Fatalf("expected 1 sentry event, got %d", len(tr.events))
	}
	if tr.events[0].Message != "ingest failed" {
		t.Fatalf("unexpected message %q", tr.events[0].Message)
	}
	if tr.events[0].Level != sentry.LevelError {
		t.Fatalf("expected error level, got %v", tr.events[0].Level)
	}
	if tr.events[0].Tags["source"] != "zap" {
		t.Fatalf("expected zap source tag, got %v", tr.events[0].Tags)
	}
	if tr.events[0].Tags["action"] != "busStatic" {
		t.Fatalf("expected action tag, got %v", tr.events[0].Tags)
	}
	if _, ok := tr.events[0].Tags["err"]; ok {
		t.Fatal("err should not be a tag")
	}
	if tr.events[0].Contexts["error"] == nil {
		t.Fatalf("expected error context, got %v", tr.events[0].Contexts)
	}
}

// Fields attached with With never reach Write, so a core that read only the
// call-site fields would drop them from the Sentry scope. Init attaches the
// service name that way, so this is the common case, not an edge one.
func TestCoreReportsWithFields(t *testing.T) {
	logger, tr := newTestLogger(t)
	logger.With("service", "functions").Errorw("ingest failed", "action", "busStatic")
	if len(tr.events) != 1 {
		t.Fatalf("expected 1 sentry event, got %d", len(tr.events))
	}
	if tr.events[0].Tags["service"] != "functions" {
		t.Fatalf("expected service tag from With, got %v", tr.events[0].Tags)
	}
}

func TestCoreWarnInfoNotReported(t *testing.T) {
	logger, tr := newTestLogger(t)
	logger.Warnw("parse skipped", "err", errors.New("bad float"))
	logger.Infow("done")
	if len(tr.events) != 0 {
		t.Fatalf("expected 0 sentry events, got %d", len(tr.events))
	}
}

func TestCoreTransientErrorNotReported(t *testing.T) {
	logger, tr := newTestLogger(t)
	logger.Errorw("connect failed", "service", "redis", "err", errors.New("dial tcp: connection refused"))
	logger.Errorw("fetch failed", "err", errors.New("context deadline exceeded"))
	if len(tr.events) != 0 {
		t.Fatalf("expected 0 sentry events for transient errors, got %d", len(tr.events))
	}
	logger.Errorw("decode failed", "err", errors.New("invalid character"))
	if len(tr.events) != 1 {
		t.Fatalf("expected the non-transient error to report, got %d events", len(tr.events))
	}
}

func TestLogTagValuesKeepTheirReadableText(t *testing.T) {
	for _, tc := range []struct {
		value any
		want  string
	}{
		{"name", "name"}, {errors.New("failure"), "failure"}, {42, "42"}, {true, "true"}, {nil, "<nil>"},
	} {
		if got := valueText(tc.value); got != tc.want {
			t.Fatalf("text(%T)=%q want=%q", tc.value, got, tc.want)
		}
	}
	logger, transport := newTestLogger(t)
	logger.Errorw("failed batch", "rows", 42, "failed", true)
	if len(transport.events) != 1 || transport.events[0].Tags["rows"] != "42" || transport.events[0].Tags["failed"] != "true" {
		t.Fatal("numeric/boolean log tags lost their values")
	}
}

// Sent as a bare message, a log line reached Sentry as one line: no exception,
// no stack and none of the attributes the error carried.
func TestCoreSendsTheErrorChainWithItsAttributes(t *testing.T) {
	logger, tr := newTestLogger(t)
	err := oops.With("status_code", 502).Wrapf(errors.New("bad gateway"), "plan motis")
	logger.Errorw("plan error", "component", "maas", "action", "plan", "event", "failed", "err", err)

	if len(tr.events) != 1 {
		t.Fatalf("expected 1 sentry event, got %d", len(tr.events))
	}
	event := tr.events[0]
	if event.Message != "plan error" || len(event.Exception) < 2 {
		t.Fatalf("event = %q with %d exceptions, want the log message and the wrapped chain", event.Message, len(event.Exception))
	}
	if outer := event.Exception[len(event.Exception)-1]; outer.Stacktrace == nil || len(outer.Stacktrace.Frames) == 0 {
		t.Fatal("outermost exception has no stack trace")
	}
	if event.Contexts["error attributes"]["status_code"] != 502 {
		t.Fatalf("error attributes = %v", event.Contexts["error attributes"])
	}
	if _, ok := event.Tags["errVerbose"]; ok {
		t.Fatalf("errVerbose sent as a tag: %v", event.Tags)
	}
	if want := []string{"plan error", "maas", "plan", "failed"}; !slices.Equal(event.Fingerprint, want) {
		t.Fatalf("fingerprint = %v, want %v", event.Fingerprint, want)
	}
}

func TestCoreFindsAnErrorAttachedWithWith(t *testing.T) {
	logger, tr := newTestLogger(t)
	logger.With("err", oops.With("city", "Taipei").Errorf("decode failed")).Errorw("ingest failed", "action", "busStatic")
	logger.Errorw("ingest stalled", "action", "busStatic")

	if len(tr.events) != 2 {
		t.Fatalf("expected 2 sentry events, got %d", len(tr.events))
	}
	if len(tr.events[0].Exception) == 0 || tr.events[0].Contexts["error attributes"]["city"] != "Taipei" {
		t.Fatalf("error attached with With was lost: %+v", tr.events[0])
	}
	if len(tr.events[1].Exception) != 0 || tr.events[1].Message != "ingest stalled" {
		t.Fatalf("message-only line = %+v, want the message and no exception", tr.events[1])
	}
}
