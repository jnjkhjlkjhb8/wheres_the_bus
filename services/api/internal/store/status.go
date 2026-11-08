package store

import (
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// GRPCStatusFor maps a failed store read onto the status an RPC returns and
// logs it, so the handler returns the status without logging again. A missing
// row or cache key means the data is not landed yet, so it logs at Warn, below
// the Error level the Sentry core reports.
func GRPCStatusFor(err error, action, notFoundMsg string) error {
	if errors.Is(err, pgx.ErrNoRows) || errors.Is(err, redis.Nil) || errors.Is(err, obs.ErrNotFound) {
		zap.S().Warnw("not found", "component", "grpc", "action", action, "event", "not_found", "err", err)
		return status.Error(codes.NotFound, notFoundMsg)
	}
	zap.S().Errorw("query failed", "component", "grpc", "action", action, "event", "query_failed", "err", err)
	obs.IncDBError()
	return status.Error(codes.Internal, "internal error")
}
