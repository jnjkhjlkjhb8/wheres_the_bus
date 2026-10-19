package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/samber/oops"
)

func TestStaticPipelinePanicPreservesFailedReleaseAndOriginalPanic(t *testing.T) {
	releaseErr := errors.New("advisory lock release failed")
	const jobPanic = "landed dataset transform panicked"
	releases := 0
	runner := staticPipelineRunner{
		gate: make(chan struct{}, 1), timeout: time.Second,
		locker: fakeStaticLocker{acquire: func(context.Context) (func() error, error) {
			return func() error {
				releases++
				return releaseErr
			}, nil
		}},
	}
	var caught any
	func() {
		defer func() { caught = recover() }()
		_ = runner.Run(context.Background(), func(context.Context) error {
			panic(jobPanic)
		})
	}()
	if releases != 1 {
		t.Fatalf("release calls after job panic = %d, want exactly one", releases)
	}
	err, ok := caught.(error)
	if !ok || !errors.Is(err, releaseErr) {
		t.Fatalf("recovered panic = %v, want preserved release error", caught)
	}
	diagnostic, ok := oops.AsOops(err)
	if !ok || diagnostic.Context()["recovered"] != jobPanic {
		t.Fatalf("recovered panic lost original job context: %v", caught)
	}
}
