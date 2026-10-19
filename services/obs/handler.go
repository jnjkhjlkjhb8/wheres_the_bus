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
	encoded := sentryFields(c.fields, fields)
	errVal, hasErr := encoded["err"]
	errText := captureErrorText(errVal, hasErr)
	if hasErr && transientErr(errText) {
		return
	}

	hub := sentry.CurrentHub().Clone()
	hub.Scope().SetLevel(sentry.LevelError)
	hub.Scope().SetTag("source", "zap")
	setLogTags(hub.Scope(), encoded)
	setCapturedError(hub.Scope(), errVal, errText, hasErr)
	hub.CaptureMessage(ent.Message)
}

func sentryFields(inherited, fields []zapcore.Field) map[string]any {
	enc := zapcore.NewMapObjectEncoder()
	for _, f := range inherited {
		f.AddTo(enc)
	}
	for _, f := range fields {
		f.AddTo(enc)
	}
	return enc.Fields
}

func setLogTags(scope *sentry.Scope, fields map[string]any) {
	for k, v := range fields {
		if k == "err" || strings.HasPrefix(k, _oopsFieldPrefix) {
			continue
		}
		scope.SetTag(k, valueText(v))
	}
}

func valueText(v any) string {
	if value, ok := v.(string); ok {
		return value
	}
	if err, ok := v.(error); ok {
		return err.Error()
	}
	return fmt.Sprint(v)
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

func captureErrorText(value any, present bool) string {
	if !present {
		return ""
	}
	return valueText(value)
}

func setCapturedError(scope *sentry.Scope, errVal any, errText string, hasErr bool) {
	if hasErr {
		scope.SetContext("error", sentry.Context{"detail": errText})
		if err, ok := errVal.(error); ok {
			applyOopsScope(scope, err)
		}
	}
}
