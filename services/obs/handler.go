package obs

import (
	"fmt"
	"slices"
	"strings"

	"github.com/getsentry/sentry-go"
	"go.uber.org/zap/zapcore"
)

type sentryCore struct {
	zapcore.Core

	// fields accumulated through With. The embedded core keeps its own copy for
	// encoding, but does not expose them, and a Sentry event needs every field
	// the logger carries -- not just the ones passed at the call site.
	fields []zapcore.Field
}

func NewCore(inner zapcore.Core) zapcore.Core {
	return &sentryCore{Core: inner}
}

func (c *sentryCore) With(fields []zapcore.Field) zapcore.Core {
	return &sentryCore{
		Core:   c.Core.With(fields),
		fields: append(slices.Clip(c.fields), fields...),
	}
}

// Check must be overridden rather than inherited: the embedded core would add
// itself to the checked entry, and this core's Write -- the Sentry hook --
// would never run.
func (c *sentryCore) Check(ent zapcore.Entry, ce *zapcore.CheckedEntry) *zapcore.CheckedEntry {
	if c.Enabled(ent.Level) {
		return ce.AddCore(ent, c)
	}
	return ce
}

func (c *sentryCore) Write(ent zapcore.Entry, fields []zapcore.Field) error {
	// Attributes attached to an error with .With() only reach the log line if
	// something lifts them off the error here; the call site logs the error as
	// one value.
	fields = expandOopsFields(fields)
	if ent.Level >= zapcore.ErrorLevel && sentry.CurrentHub().Client() != nil {
		c.capture(ent, fields)
	}
	return c.Core.Write(ent, fields)
}

func (c *sentryCore) capture(ent zapcore.Entry, fields []zapcore.Field) {
	enc := zapcore.NewMapObjectEncoder()
	for _, f := range c.fields {
		f.AddTo(enc)
	}
	for _, f := range fields {
		f.AddTo(enc)
	}

	errVal, hasErr := enc.Fields["err"]
	errText := ""
	if hasErr {
		errText = valueText(errVal)
		if transientErr(errText) {
			return
		}
	}

	hub := sentry.CurrentHub().Clone()
	hub.Scope().SetLevel(sentry.LevelError)
	hub.Scope().SetTag("source", "zap")
	for k, v := range enc.Fields {
		if k == "err" || strings.HasPrefix(k, _oopsFieldPrefix) {
			continue
		}
		hub.Scope().SetTag(k, valueText(v))
	}
	if hasErr {
		hub.Scope().SetContext("error", sentry.Context{"detail": errText})
		if err, ok := errVal.(error); ok {
			applyOopsScope(hub.Scope(), err)
		}
	}
	hub.CaptureMessage(ent.Message)
}

func valueText(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case error:
		return t.Error()
	default:
		return fmt.Sprint(v)
	}
}

func transientErr(val string) bool {
	lower := strings.ToLower(val)
	for _, s := range []string{"context deadline exceeded", "timeout", "connection refused", "connection reset", "loading redis"} {
		if strings.Contains(lower, s) {
			return true
		}
	}
	return false
}
