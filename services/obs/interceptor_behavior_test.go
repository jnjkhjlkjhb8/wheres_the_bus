package obs

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/getsentry/sentry-go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type contextServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s contextServerStream) Context() context.Context { return s.ctx }

func TestUnaryInterceptorMapsPanicsAndPreservesResults(t *testing.T) {
	_, transport := newTestLogger(t)
	resetMetricsForTest()
	interceptor := UnaryInterceptor()
	info := &grpc.UnaryServerInfo{FullMethod: "/quality.Service/Unary"}
	result, err := interceptor(context.Background(), "request", info, func(ctx context.Context, req any) (any, error) {
		if sentry.GetHubFromContext(ctx) == nil || req != "request" {
			t.Fatal("request context lost")
		}
		return "response", nil
	})
	if result != "response" || err != nil {
		t.Fatalf("result=%v err=%v", result, err)
	}
	expected := errors.New("handler failed")
	_, err = interceptor(context.Background(), nil, info, func(context.Context, any) (any, error) { return nil, expected })
	if !errors.Is(err, expected) {
		t.Fatalf("handler error changed: %v", err)
	}
	_, err = interceptor(context.Background(), nil, info, func(context.Context, any) (any, error) { panic("unary panic") })
	if status.Code(err) != codes.Internal || len(transport.events) != 1 {
		t.Fatalf("panic err=%v events=%d", err, len(transport.events))
	}
	if transport.events[0].Tags["grpc.method"] != info.FullMethod {
		t.Fatal("panic lacks method attribution")
	}
	if !strings.Contains(MetricsText(), `router_grpc_requests_total{method="/quality.Service/Unary"} 3`) || !strings.Contains(MetricsText(), `router_grpc_errors_total{method="/quality.Service/Unary"} 2`) {
		t.Fatal("unary metrics omit failures")
	}
}

func TestStreamInterceptorMapsPanicsAndPreservesErrors(t *testing.T) {
	_, transport := newTestLogger(t)
	resetMetricsForTest()
	interceptor := StreamInterceptor()
	info := &grpc.StreamServerInfo{FullMethod: "/quality.Service/Stream"}
	stream := contextServerStream{ctx: context.Background()}
	if err := interceptor("server", stream, info, func(srv any, got grpc.ServerStream) error {
		if srv != "server" || got.Context() != stream.ctx {
			t.Fatal("stream request changed")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	expected := errors.New("stream failed")
	if err := interceptor(nil, stream, info, func(any, grpc.ServerStream) error { return expected }); !errors.Is(err, expected) {
		t.Fatal(err)
	}
	err := interceptor(nil, stream, info, func(any, grpc.ServerStream) error { panic("stream panic") })
	if status.Code(err) != codes.Internal || len(transport.events) != 1 {
		t.Fatalf("panic err=%v events=%d", err, len(transport.events))
	}
	if !strings.Contains(MetricsText(), `router_grpc_requests_total{method="/quality.Service/Stream"} 3`) {
		t.Fatal("stream metrics absent")
	}
}

func TestRecoverReportsAndRepanics(t *testing.T) {
	_, transport := newTestLogger(t)
	func() { defer Recover("without-panic") }()
	if len(transport.events) != 0 {
		t.Fatal("reported a successful job")
	}
	recovered := func() (caught any) {
		defer func() { caught = recover() }()
		func() { defer Recover("quality-job"); panic("job panic") }()
		return nil
	}()
	if recovered != "job panic" || len(transport.events) != 1 || transport.events[0].Tags["job"] != "quality-job" {
		t.Fatalf("recovered=%v events=%v", recovered, transport.events)
	}
}
