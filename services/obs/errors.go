package obs

import (
	"errors"

	"github.com/samber/oops"
)

var (
	// ErrTransient marks a failure worth retrying. Retry only re-attempts
	// errors that wrap this sentinel; wrap with Transient at the call site.
	ErrTransient = errors.New("transient")
	// ErrNotFound marks a missing resource. It is distinct from ErrTransient
	// so callers can match on it and stop rather than retry.
	ErrNotFound = errors.New("not found")
)

// Transient wraps err so it satisfies errors.Is(_, ErrTransient), marking it
// as retryable for Retry. A nil err returns nil so this can wrap a result
// unconditionally.
func Transient(err error) error {
	if err == nil {
		return nil
	}
	return oops.Join(ErrTransient, err)
}

// NotFound wraps err so it satisfies errors.Is(_, ErrNotFound). A nil err
// returns nil so this can wrap a result unconditionally.
func NotFound(err error) error {
	if err == nil {
		return nil
	}
	return oops.Join(ErrNotFound, err)
}
