package shared

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestPingWithRetrySucceedsAfterRefusals(t *testing.T) {
	calls := 0
	err := pingWithRetry(func(context.Context) error {
		calls++
		if calls < 3 {
			return errors.New("connection refused")
		}
		return nil
	}, 5, time.Millisecond)
	if err != nil {
		t.Fatalf("pingWithRetry() = %v, want nil after the third attempt", err)
	}
	if calls != 3 {
		t.Fatalf("ping called %d times, want 3", calls)
	}
}

func TestPingWithRetryGivesUpWithTheLastError(t *testing.T) {
	want := errors.New("still refused")
	calls := 0
	err := pingWithRetry(func(context.Context) error {
		calls++
		return want
	}, 4, time.Millisecond)
	if !errors.Is(err, want) {
		t.Fatalf("pingWithRetry() = %v, want %v", err, want)
	}
	if calls != 4 {
		t.Fatalf("ping called %d times, want 4", calls)
	}
}
