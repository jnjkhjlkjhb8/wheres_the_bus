package obs

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"testing"
)

func TestWithoutURL(t *testing.T) {
	plain := errors.New("plain failure")
	tests := []struct {
		name  string
		err   error
		want  string
		cause error
	}{
		{
			name:  "url error",
			err:   &url.Error{Op: "Post", URL: "http://127.0.0.1:1/api/webhooks/1/SECRETTOKEN", Err: context.DeadlineExceeded},
			want:  "Post: context deadline exceeded",
			cause: context.DeadlineExceeded,
		},
		{name: "plain error", err: plain, want: "plain failure", cause: plain},
		{name: "nil", err: nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := WithoutURL(tt.err)
			if tt.err == nil {
				if got != nil {
					t.Fatalf("WithoutURL(nil) = %v", got)
				}
				return
			}
			if got.Error() != tt.want || strings.Contains(got.Error(), "SECRETTOKEN") {
				t.Fatalf("WithoutURL() = %q, want %q", got, tt.want)
			}
			if !errors.Is(got, tt.cause) {
				t.Fatalf("WithoutURL() = %v lost cause %v", got, tt.cause)
			}
		})
	}
	if got := WithoutURL(plain); got != plain {
		t.Fatalf("plain error was rewrapped: %v", got)
	}
}
