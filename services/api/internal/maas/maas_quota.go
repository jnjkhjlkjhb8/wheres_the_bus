package maas

// The MaaS per-caller TDX quota: config, accounting, and the unary/stream
// interceptors that charge it. Kept apart from MaasServer because it governs
// who may start work, while MaasServer governs the work already in flight.

import (
	"context"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type MaasResourceConfig struct {
	RateLimit  int
	RateWindow time.Duration
}

var DefaultMaasResourceConfig = MaasResourceConfig{
	RateLimit:  5,
	RateWindow: time.Minute,
}

const _maasQuotaScope = "maas:plan"

func maasPlanQuota(ctx context.Context, rl *ratelimit.Limiter, config MaasResourceConfig) error {
	if err := ctx.Err(); err != nil {
		return status.FromContextError(err).Err()
	}
	if !ratelimit.Allow(ctx, rl, _maasQuotaScope, config.RateLimit, config.RateWindow) {
		return status.Error(codes.ResourceExhausted, "MaaS rate limit exceeded")
	}
	if err := ctx.Err(); err != nil {
		return status.FromContextError(err).Err()
	}
	return nil
}

// MaasResourceInterceptor contains the per-caller TDX quota independently from
// unrelated gRPC methods. Shared-work concurrency and deadlines belong to
// MaasServer so singleflight work retains them after an individual caller exits.
func MaasResourceInterceptor(rl *ratelimit.Limiter, config MaasResourceConfig) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if info.FullMethod != pb.MaasService_Plan_FullMethodName {
			return handler(ctx, req)
		}
		if err := maasPlanQuota(ctx, rl, config); err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

// MaasResourceStreamInterceptor is the streaming half of the same quota. Without
// it planStream would reach TDX with no per-caller ceiling at all.
func MaasResourceStreamInterceptor(rl *ratelimit.Limiter, config MaasResourceConfig) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if info.FullMethod != pb.MaasService_PlanStream_FullMethodName {
			return handler(srv, ss)
		}
		if err := maasPlanQuota(ss.Context(), rl, config); err != nil {
			return err
		}
		return handler(srv, ss)
	}
}
