package obs

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/samber/oops"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// logLine writes one error entry through the production core stack into a
// buffer and returns the decoded JSON.
func logLine(t *testing.T, err error) map[string]any {
	t.Helper()
	var buf strings.Builder
	encoder := zapcore.EncoderConfig{
		TimeKey: zapcore.OmitKey, LevelKey: "level", MessageKey: "msg",
		NameKey: zapcore.OmitKey, CallerKey: zapcore.OmitKey,
		FunctionKey: zapcore.OmitKey, StacktraceKey: zapcore.OmitKey,
		LineEnding: zapcore.DefaultLineEnding, EncodeLevel: zapcore.CapitalLevelEncoder,
	}
	inner := zapcore.NewCore(zapcore.NewJSONEncoder(encoder), zapcore.AddSync(&buf), zapcore.InfoLevel)
	zap.New(NewCore(inner)).Sugar().Errorw("load failed", "err", err)
	var line map[string]any
	if decodeErr := json.Unmarshal([]byte(buf.String()), &line); decodeErr != nil {
		t.Fatalf("log line is not JSON: %v (%q)", decodeErr, buf.String())
	}
	return line
}

// An error's .With() attributes only pay for themselves if they survive to the
// log backend as queryable fields instead of being flattened into the message.
func TestLogExpandsStructuredErrorAttributes(t *testing.T) {
	err := oops.In("functions").
		Code("load_failed").
		Tags("postgres").
		With("city", "Taipei").
		With("rows", 12).
		Wrapf(errors.New("connection refused"), "load bus city")

	line := logLine(t, err)

	for key, want := range map[string]any{
		"err.domain": "functions",
		"err.code":   "load_failed",
		"err.city":   "Taipei",
		"err.rows":   float64(12), // JSON numbers decode as float64
	} {
		if line[key] != want {
			t.Errorf("%s = %#v, want %#v", key, line[key], want)
		}
	}
	if tags, _ := line["err.tags"].([]any); len(tags) != 1 || tags[0] != "postgres" {
		t.Errorf("err.tags = %#v, want [postgres]", line["err.tags"])
	}
	// The message stays low-cardinality: the values live in the fields above.
	if msg, _ := line["msg"].(string); msg != "load failed" {
		t.Errorf("msg = %q, want %q", msg, "load failed")
	}
}

// A plain error must log exactly as before, or every non-oops call site would
// start emitting empty err.* fields.
func TestLogLeavesPlainErrorsAlone(t *testing.T) {
	line := logLine(t, errors.New("boom"))
	for key := range line {
		if strings.HasPrefix(key, _oopsFieldPrefix) {
			t.Errorf("plain error produced %q", key)
		}
	}
	if line["err"] != "boom" {
		t.Errorf("err = %#v, want \"boom\"", line["err"])
	}
}
