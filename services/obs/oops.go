package obs

import (
	"errors"
	"sort"

	"github.com/getsentry/sentry-go"
	"github.com/samber/oops"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// _oopsFieldPrefix namespaces attributes lifted off an error so they cannot
// collide with fields the call site already logs under the same name (a
// handler logging "city" and an error carrying "city" are different facts).
const _oopsFieldPrefix = "err."

// structuredError returns the outermost oops error in err's chain. oops merges
// the context of every oops error along the chain into that one value, so a
// single lookup yields every attribute added at every layer.
func structuredError(err error) (oops.OopsError, bool) {
	var structured oops.OopsError
	if err == nil || !errors.As(err, &structured) {
		return oops.OopsError{}, false
	}
	return structured, true
}

func oopsFields(err error) []zapcore.Field {
	structured, ok := structuredError(err)
	if !ok {
		return nil
	}
	var fields []zapcore.Field
	if domain := structured.Domain(); domain != "" {
		fields = append(fields, zap.String(_oopsFieldPrefix+"domain", domain))
	}
	if code, ok := structured.Code().(string); ok && code != "" {
		fields = append(fields, zap.String(_oopsFieldPrefix+"code", code))
	}
	if tags := structured.Tags(); len(tags) > 0 {
		fields = append(fields, zap.Strings(_oopsFieldPrefix+"tags", tags))
	}
	context := structured.Context()
	keys := make([]string, 0, len(context))
	for key := range context {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		fields = append(fields, zap.Any(_oopsFieldPrefix+key, context[key]))
	}
	return fields
}

// expandOopsFields returns fields with every error field's structured context
// appended. Entries without an oops error in them are returned untouched, and
// the input slice is never mutated.
func expandOopsFields(fields []zapcore.Field) []zapcore.Field {
	var extra []zapcore.Field
	for _, field := range fields {
		if field.Type != zapcore.ErrorType {
			continue
		}
		err, ok := field.Interface.(error)
		if !ok {
			continue
		}
		extra = append(extra, oopsFields(err)...)
	}
	if len(extra) == 0 {
		return fields
	}
	out := make([]zapcore.Field, 0, len(fields)+len(extra))
	out = append(out, fields...)
	return append(out, extra...)
}

func applyOopsScope(scope *sentry.Scope, err error) {
	structured, ok := structuredError(err)
	if !ok {
		return
	}
	if domain := structured.Domain(); domain != "" {
		scope.SetTag("err.domain", domain)
	}
	if code, ok := structured.Code().(string); ok && code != "" {
		scope.SetTag("err.code", code)
	}
	for _, tag := range structured.Tags() {
		scope.SetTag("err.tag."+tag, "true")
	}
	if context := structured.Context(); len(context) > 0 {
		block := make(sentry.Context, len(context))
		for key, value := range context {
			block[key] = value
		}
		scope.SetContext("error attributes", block)
	}
	if trace := structured.Stacktrace(); trace != "" {
		scope.SetContext("error stacktrace", sentry.Context{"frames": trace})
	}
}
