package marker

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSleepCtxReturnsCancellationOrElapsedDelay(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := SleepCtx(ctx, time.Hour); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled sleep = %v", err)
	}
	if err := SleepCtx(context.Background(), time.Millisecond); err != nil {
		t.Fatalf("elapsed sleep = %v", err)
	}
}
