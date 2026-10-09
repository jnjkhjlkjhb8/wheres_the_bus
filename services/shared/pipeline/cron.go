package pipeline

import (
	"context"
	"time"

	"go.uber.org/zap"
)

// runDaily runs a daily job under a d timeout, retrying up to 3 times with a
// one-minute backoff (obs.Retry). Exhausted retries are logged, not fatal — the
// next daily tick retries.
func RunDaily(name string, d time.Duration, job func(context.Context) error) {
	err := RunDailyWithRetry(context.Background(), d, time.Minute, job)
	if err != nil {
		zap.S().Errorw("failed", "component", "crontab", "action", name, "event", "failed", "err", err)
	}
}
