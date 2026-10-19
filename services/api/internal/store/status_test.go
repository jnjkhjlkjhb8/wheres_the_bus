package store

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestGRPCStatusForMissingData(t *testing.T) {
	for _, cause := range []error{pgx.ErrNoRows, redis.Nil, obs.ErrNotFound} {
		got := GRPCStatusFor(fmt.Errorf("read: %w", cause), "station not found")
		if status.Code(got) != codes.NotFound || status.Convert(got).Message() != "station not found" {
			t.Fatalf("status for %v = %v, want NotFound with caller message", cause, got)
		}
	}
}

func TestGRPCStatusForDatabaseFailureDoesNotExposeDetails(t *testing.T) {
	got := GRPCStatusFor(errors.New("private database detail"), "station not found")
	if status.Code(got) != codes.Internal || status.Convert(got).Message() != "internal error" || strings.Contains(got.Error(), "private") {
		t.Fatalf("database failure status = %v", got)
	}
}
