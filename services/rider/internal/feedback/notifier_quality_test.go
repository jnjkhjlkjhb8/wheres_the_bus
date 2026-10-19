package feedback

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestWebhookNotifierDeliversReportAsynchronously(t *testing.T) {
	received := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
		}
		received <- string(body)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	notifier := &webhookNotifier{url: server.URL, client: server.Client()}
	notifier.Notify(feedbackNotice{ThreadID: "quality-thread", Category: "eta", Body: "where is my bus"})
	select {
	case body := <-received:
		if !strings.Contains(body, "where is my bus") || !strings.Contains(body, `"allowed_mentions":{"parse":[]}`) {
			t.Fatalf("payload=%s", body)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("async webhook was not delivered")
	}
}
