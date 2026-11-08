package store

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestGRPCStatusForMissingData(t *testing.T) {
	for _, cause := range []error{pgx.ErrNoRows, redis.Nil, obs.ErrNotFound} {
		got := GRPCStatusFor(fmt.Errorf("read: %w", cause), "station", "station not found")
		if status.Code(got) != codes.NotFound || status.Convert(got).Message() != "station not found" {
			t.Fatalf("status for %v = %v, want NotFound with caller message", cause, got)
		}
	}
}

func TestGRPCStatusForDatabaseFailureDoesNotExposeDetails(t *testing.T) {
	got := GRPCStatusFor(errors.New("private database detail"), "station", "station not found")
	if status.Code(got) != codes.Internal || status.Convert(got).Message() != "internal error" || strings.Contains(got.Error(), "private") {
		t.Fatalf("database failure status = %v", got)
	}
}

// The Sentry core reports Error and above, so a cache miss logged at Error
// paged as a failure (FDPL-128).
func TestGRPCStatusForLogsMissingDataBelowSentryLevel(t *testing.T) {
	core, logs := observer.New(zapcore.DebugLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))

	_ = GRPCStatusFor(redis.Nil, "bus_dailytable", "timetable not found")
	_ = GRPCStatusFor(errors.New("connection reset"), "bus_static", "route not found")

	entries := logs.AllUntimed()
	if len(entries) != 2 {
		t.Fatalf("got %d log entries, want 2", len(entries))
	}
	assertLogEntry(t, entries[0], zapcore.WarnLevel, "bus_dailytable")
	assertLogEntry(t, entries[1], zapcore.ErrorLevel, "bus_static")
}

func assertLogEntry(t *testing.T, entry observer.LoggedEntry, level zapcore.Level, action string) {
	t.Helper()
	fields := entry.ContextMap()
	if entry.Level != level || fields["action"] != action || fields["err"] == nil {
		t.Fatalf("log entry = %v %v, want %v with action %q and err", entry.Level, fields, level, action)
	}
}
