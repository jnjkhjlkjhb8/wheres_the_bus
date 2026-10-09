package obs

import (
	"context"
	"errors"
	"time"
)

func Retry(ctx context.Context, attempts int, base time.Duration, fn func() error) error {
	var err error
	for i := range attempts {
		if i > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(base << (i - 1)):
			}
		}
		err = fn()
		if err == nil || !errors.Is(err, ErrTransient) {
			return err
		}
	}
	return err
}
