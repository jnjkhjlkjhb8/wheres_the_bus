package obs

import (
	"context"
	"net/url"
	"os"
	"strconv"
	"time"

	"github.com/getsentry/sentry-go"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func Init(service string) func() {
	logger := zap.New(NewCore(newZapCore())).With(zap.String("service", service))
	zap.ReplaceGlobals(logger)
	// zap buffers nothing when writing straight to stderr, but Sync is the
	// documented contract and keeps this correct if the sink ever changes.
	sync := func() { _ = logger.Sync() }
	dsn := os.Getenv("SENTRY_DSN")
	if dsn == "" {
		zap.S().Infow("sentry disabled", "reason", "no_dsn")
		return sync
	}
	tracesRate := 0.1
	if v := os.Getenv("SENTRY_TRACES_SAMPLE_RATE"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			tracesRate = f
		}
	}
	err := sentry.Init(sentry.ClientOptions{
		Dsn:                   dsn,
		Environment:           os.Getenv("SENTRY_ENVIRONMENT"),
		ServerName:            service,
		EnableTracing:         tracesRate > 0,
		TracesSampleRate:      tracesRate,
		BeforeSend:            scrubSentryEventQuery,
		BeforeSendTransaction: scrubSentryEventQuery,
	})
	if err != nil {
		zap.S().Errorw("sentry init failed", "err", err)
		return sync
	}
	sentry.ConfigureScope(func(scope *sentry.Scope) {
		scope.SetTag("service", service)
	})
	zap.S().Infow("sentry enabled", "traces", tracesRate)
	return func() {
		sentry.Flush(2 * time.Second)
		sync()
	}
}

func newZapCore() zapcore.Core {
	encoder := zapcore.EncoderConfig{
		TimeKey:        "time",
		LevelKey:       "level",
		MessageKey:     "msg",
		NameKey:        zapcore.OmitKey,
		CallerKey:      zapcore.OmitKey,
		FunctionKey:    zapcore.OmitKey,
		StacktraceKey:  zapcore.OmitKey,
		LineEnding:     zapcore.DefaultLineEnding,
		EncodeLevel:    zapcore.CapitalLevelEncoder,
		EncodeTime:     zapcore.RFC3339NanoTimeEncoder,
		EncodeDuration: zapcore.StringDurationEncoder,
	}
	return zapcore.NewCore(zapcore.NewJSONEncoder(encoder), zapcore.Lock(os.Stderr), zapcore.InfoLevel)
}

// scrubSentryEventQuery removes credentials and other query parameters from
// both error and transaction events while retaining the request path and method.
func scrubSentryEventQuery(event *sentry.Event, _ *sentry.EventHint) *sentry.Event {
	if event == nil || event.Request == nil {
		return event
	}
	event.Request.QueryString = ""
	if parsed, err := url.Parse(event.Request.URL); err == nil {
		parsed.RawQuery = ""
		parsed.ForceQuery = false
		event.Request.URL = parsed.String()
	}
	return event
}

func Recover(name string) {
	if r := recover(); r != nil {
		hub := sentry.CurrentHub().Clone()
		hub.Scope().SetTag("job", name)
		hub.RecoverWithContext(context.Background(), r)
		hub.Flush(2 * time.Second)
		panic(r)
	}
}

func Capture(name string, err error) {
	if err == nil {
		return
	}
	hub := sentry.CurrentHub().Clone()
	hub.Scope().SetTag("job", name)
	applyOopsScope(hub.Scope(), err)
	hub.CaptureException(err)
}

func UnaryInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (_ any, err error) {
		hub := sentry.CurrentHub().Clone()
		hub.Scope().SetTag("grpc.method", info.FullMethod)
		ctx = sentry.SetHubOnContext(ctx, hub)
		defer func() {
			if r := recover(); r != nil {
				hub.RecoverWithContext(ctx, r)
				err = status.Errorf(codes.Internal, "internal error")
			}
			RecordGRPCRequest(info.FullMethod, err)
		}()
		return handler(ctx, req)
	}
}

func StreamInterceptor() grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) (err error) {
		hub := sentry.CurrentHub().Clone()
		hub.Scope().SetTag("grpc.method", info.FullMethod)
		defer func() {
			if r := recover(); r != nil {
				hub.RecoverWithContext(ss.Context(), r)
				err = status.Errorf(codes.Internal, "internal error")
			}
			RecordGRPCRequest(info.FullMethod, err)
		}()
		return handler(srv, ss)
	}
}
