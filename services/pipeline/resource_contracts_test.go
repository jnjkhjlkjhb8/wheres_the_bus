package main

import (
	"errors"
	"testing"

	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestPipelineResourceCloseReportsOnlyActualFailures(t *testing.T) {
	want := errors.New("raw connection close failed")
	for _, closeErr := range []error{nil, want} {
		name := "success"
		if closeErr != nil {
			name = "failure"
		}
		t.Run(name, func(t *testing.T) {
			core, logs := observer.New(zap.ErrorLevel)
			t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
			calls := 0
			closePipelineResource(func() error {
				calls++
				return closeErr
			}, "raw")
			if calls != 1 {
				t.Fatalf("resource close calls = %d, want exactly one", calls)
			}
			if closeErr == nil {
				if logs.Len() != 0 {
					t.Fatalf("successful close emitted errors: %v", logs.All())
				}
				return
			}
			entries := logs.All()
			if len(entries) != 1 || entries[0].Message != "failed" {
				t.Fatalf("failed close logs = %v, want one failed event", entries)
			}
			fields := entries[0].ContextMap()
			if fields["component"] != "raw" || fields["action"] != "close" || fields["event"] != "failed" || fields["err"] != want.Error() {
				t.Fatalf("failed close diagnostic = %v", fields)
			}
		})
	}
}
