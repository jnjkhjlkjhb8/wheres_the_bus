package store

import (
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func GRPCStatusFor(err error, notFoundMsg string) error {
	if errors.Is(err, pgx.ErrNoRows) || errors.Is(err, redis.Nil) || errors.Is(err, obs.ErrNotFound) {
		return status.Error(codes.NotFound, notFoundMsg)
	}
	obs.IncDBError()
	return status.Error(codes.Internal, "internal error")
}
