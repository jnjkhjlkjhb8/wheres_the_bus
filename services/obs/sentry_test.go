package obs

import (
	"testing"

	"github.com/getsentry/sentry-go"
)

func TestScrubSentryEventQueryPreservesRequestPathAndMethod(t *testing.T) {
	for _, eventType := range []string{"error", "transaction"} {
		t.Run(eventType, func(t *testing.T) {
			event := sentry.NewEvent()
			if eventType == "transaction" {
				event.Type = "transaction"
			}
			event.Request = &sentry.Request{
				URL:         "https://router.example/metrics?token=super-secret",
				Method:      "GET",
				QueryString: "token=super-secret",
			}

			got := scrubSentryEventQuery(event, nil)
			if got == nil || got.Request == nil {
				t.Fatal("scrubber dropped event request metadata")
			}
			if got.Request.QueryString != "" {
				t.Fatalf("query string = %q, want empty", got.Request.QueryString)
			}
			if got.Request.URL != "https://router.example/metrics" {
				t.Fatalf("request URL = %q, want query-free path URL", got.Request.URL)
			}
			if got.Request.Method != "GET" {
				t.Fatalf("request method = %q", got.Request.Method)
			}
		})
	}
}
