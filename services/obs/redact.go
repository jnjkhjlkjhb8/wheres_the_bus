package obs

import (
	"errors"
	"fmt"
	"net/url"
)

// WithoutURL drops the request URL from a *url.Error in err's chain, because a
// webhook URL carries its secret token and the error is logged and reported.
// The op and the cause stay, so errors.Is still matches timeouts and
// cancellation. Any other error, including nil, is returned unchanged.
func WithoutURL(err error) error {
	var ue *url.Error
	if !errors.As(err, &ue) {
		return err
	}
	return fmt.Errorf("%s: %w", ue.Op, ue.Err)
}
