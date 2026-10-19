package shared

import (
	"context"
	"errors"
	"github.com/redis/go-redis/v9"
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

func TestRedisPingRetryPreservesLastFailureAndStopsOnSuccess(t *testing.T) {
	want := errors.New("Redis refused")
	for _, succeedAt := range []int{1, 3, 10, 11} {
		calls := 0
		pong, err := pingRedisWithRetry(func(ctx context.Context) *redis.StatusCmd {
			calls++
			cmd := redis.NewStatusCmd(ctx, "ping")
			if calls >= succeedAt {
				cmd.SetVal("PONG")
			} else {
				cmd.SetErr(want)
			}
			return cmd
		}, 0)
		if succeedAt <= 10 {
			if err != nil || pong != "PONG" || calls != succeedAt {
				t.Fatalf("success at %d calls=%d pong=%s err=%v", succeedAt, calls, pong, err)
			}
		} else if calls != 10 || pong != "" || !errors.Is(err, want) {
			t.Fatalf("retry exhaustion calls=%d pong=%s err=%v", calls, pong, err)
		}
	}
}
