package obs

import (
	"context"
	"errors"
	"time"
)

func Retry(ctx context.Context, attempts int, base time.Duration, fn func() error) error {
	var err error
	for i := range attempts {
		if err := waitRetryAttempt(ctx, i, base); err != nil {
			return err
		}
		err = fn()
		if !retryableError(err) {
			return err
		}
	}
	return err
}

func waitRetryAttempt(ctx context.Context, attempt int, base time.Duration) error {
	if attempt == 0 {
		return nil
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(base << (attempt - 1)):
		return nil
	}
}

func retryableError(err error) bool { return err != nil && errors.Is(err, ErrTransient) }
