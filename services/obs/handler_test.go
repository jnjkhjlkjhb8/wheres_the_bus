package obs

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"
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
