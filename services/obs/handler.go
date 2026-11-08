package obs

import (
	"fmt"
	"slices"
	"strings"

	"github.com/getsentry/sentry-go"
	"go.uber.org/zap/zapcore"
)

// _errorTextKeys are the keys zap encodes an error field under: its text, and
// its %+v form or causes for rich errors. The event's exception already holds
// them, and Sentry rejects a multi-line tag value.
var _errorTextKeys = map[string]bool{"err": true, "errVerbose": true, "errCauses": true}

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

	err := fieldError(slices.Concat(fields, c.fields))
	hub := sentry.CurrentHub().Clone()
	scope := hub.Scope()
	scope.SetLevel(sentry.LevelError)
	scope.SetTag("source", "zap")
	scope.SetFingerprint(logFingerprint(ent.Message, encoded))
	setLogTags(scope, encoded)
	setCapturedError(scope, errText, hasErr, err)
	hub.CaptureEvent(logEvent(hub.Client(), ent.Message, err))
}

// logEvent builds the Sentry event for a log line. A bare message reached
// Sentry as one line with no stack, so an error goes in as its unwrapped chain
// instead: oops errors bring the stack of where they were created, and any
// other error gets the stack of this call.
func logEvent(client *sentry.Client, message string, err error) *sentry.Event {
	if err == nil {
		return client.EventFromMessage(message, sentry.LevelError)
	}
	event := client.EventFromException(err, sentry.LevelError)
	event.Message = message
	return event
}

// fieldError returns the first error value among fields. The encoded field map
// holds only the error's text; its chain, stack and oops attributes live on the
// value.
func fieldError(fields []zapcore.Field) error {
	for _, field := range fields {
		if err := oopsFieldError(field); err != nil {
			return err
		}
	}
	return nil
}

// logFingerprint groups events by the site that logged them. Sites share
// messages such as "query failed", and grouping on the message alone merged
// unrelated failures into one issue.
func logFingerprint(message string, fields map[string]any) []string {
	return []string{message, valueText(fields["component"]), valueText(fields["action"]), valueText(fields["event"])}
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
		if _errorTextKeys[k] || strings.HasPrefix(k, _oopsFieldPrefix) {
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

func setCapturedError(scope *sentry.Scope, errText string, hasErr bool, err error) {
	applyOopsScope(scope, err)
	if hasErr {
		scope.SetContext("error", sentry.Context{"detail": errText})
	}
}
