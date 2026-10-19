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
	fields = appendOopsString(fields, "domain", structured.Domain())
	code, _ := structured.Code().(string)
	fields = appendOopsString(fields, "code", code)

	if tags := structured.Tags(); len(tags) > 0 {
		fields = append(fields, zap.Strings(_oopsFieldPrefix+"tags", tags))
	}
	fields = append(fields, oopsContextFields(structured.Context())...)
	return fields
}

// expandOopsFields returns fields with every error field's structured context
// appended. Entries without an oops error in them are returned untouched, and
// the input slice is never mutated.
func expandOopsFields(fields []zapcore.Field) []zapcore.Field {
	extra := extraOopsFields(fields)
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
	setOopsTags(scope, structured)
	setOopsContexts(scope, structured)
}

func setOopsTags(scope *sentry.Scope, structured oops.OopsError) {
	setOopsStringTag(scope, "err.domain", structured.Domain())
	code, _ := structured.Code().(string)
	setOopsStringTag(scope, "err.code", code)

	for _, tag := range structured.Tags() {
		scope.SetTag("err.tag."+tag, "true")
	}
}

func setOopsContexts(scope *sentry.Scope, structured oops.OopsError) {
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

func oopsContextFields(context map[string]any) []zapcore.Field {
	var fields []zapcore.Field
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

func appendOopsString(fields []zapcore.Field, key, value string) []zapcore.Field {
	if value != "" {
		fields = append(fields, zap.String(_oopsFieldPrefix+key, value))
	}
	return fields
}

func extraOopsFields(fields []zapcore.Field) []zapcore.Field {
	var extra []zapcore.Field
	for _, field := range fields {
		extra = append(extra, oopsFields(oopsFieldError(field))...)
	}
	return extra
}

func oopsFieldError(field zapcore.Field) error {
	if field.Type != zapcore.ErrorType {
		return nil
	}
	err, _ := field.Interface.(error)
	return err
}

func setOopsStringTag(scope *sentry.Scope, key, value string) {
	if value != "" {
		scope.SetTag(key, value)
	}
}
