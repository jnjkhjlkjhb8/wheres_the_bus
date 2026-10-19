package maas

import (
	"context"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestCompletedPlanCacheWriteLogsOnlyActiveFailures(t *testing.T) {
	for _, name := range []string{"success", "active failure", "cancelled failure"} {
		t.Run(name, func(t *testing.T) {
			core, observed := observer.New(zap.DebugLevel)
			restore := zap.ReplaceGlobals(zap.New(core))
			defer restore()
			base := newControlledMaasCache()
			var cache MaasCache = base
			ctx := t.Context()
			if name != "success" {
				cache = failingMaasCache{base}
			}
			if name == "cancelled failure" {
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			server := &MaasServer{cache: cache}
			server.cachePlan(ctx, "stream", &pb.MaasPlanResponse{NextPageCursor: "next"})
			if base.setCalls.Load() != 1 {
				t.Fatal("completed plan cache write was not attempted exactly once")
			}
			entries := observed.All()
			if name != "active failure" {
				if len(entries) != 0 {
					t.Fatalf("%s emitted unexpected operational error: %v", name, entries)
				}
				return
			}
			if len(entries) != 1 || entries[0].Level != zap.ErrorLevel || entries[0].Message != "cache set failed" {
				t.Fatalf("active cache failure logs = %v", entries)
			}
			fields := entries[0].ContextMap()
			if fields["component"] != "maas" || fields["err"] != "cache unavailable" {
				t.Fatalf("active cache failure metadata = %v", fields)
			}
		})
	}
}
