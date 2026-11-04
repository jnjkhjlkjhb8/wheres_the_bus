package ratelimit

import (
	"context"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// InFlightUnaryInterceptor rejects a unary call with ResourceExhausted while
// limit calls are already running. Overload then sheds work instead of
// growing the heap until the container is OOMKilled. It never queues: a
// waiting call holds its request in memory just as a running one does.
func InFlightUnaryInterceptor(limit int) grpc.UnaryServerInterceptor {
	slots := make(chan struct{}, limit)
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		select {
		case slots <- struct{}{}:
		default:
			return nil, status.Error(codes.ResourceExhausted, "server busy")
		}
		defer func() { <-slots }()
		return handler(ctx, req)
	}
}
