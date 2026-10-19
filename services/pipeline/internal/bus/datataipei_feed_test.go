package bus

import (
	"bytes"
	"compress/gzip"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-resty/resty/v2"
)

func TestDataTaipeiEnvelopeCachesOnlySuccessfullyDecodedResponses(t *testing.T) {
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write([]byte(`{"value":7}`)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Path != "/GetSpecTimeTable.gz" {
			t.Errorf("path = %s", r.URL.Path)
		}
		if requests > 1 {
			if got := r.Header.Get("If-None-Match"); got != `"version-1"` {
				t.Errorf("conditional marker = %q", got)
			}
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"version-1"`)
		_, _ = w.Write(compressed.Bytes())
	}))
	defer server.Close()
	feed := &dataTaipeiFeed{client: resty.New().SetBaseURL(server.URL), city: "Taipei", etag: map[string]string{}}
	var decoded struct {
		Value int `json:"value"`
	}
	changed, err := feed.getEnvelope(context.Background(), "GetSpecTimeTable", &decoded)
	if err != nil || !changed || decoded.Value != 7 {
		t.Fatalf("first response = %v,%v,%+v", changed, err, decoded)
	}
	decoded.Value = 9
	changed, err = feed.getEnvelope(context.Background(), "GetSpecTimeTable", &decoded)
	if err != nil || changed || decoded.Value != 9 {
		t.Fatalf("304 changed stored copy: %v,%v,%+v", changed, err, decoded)
	}
}

func TestDataTaipeiEnvelopeRejectsHTTPCompressionAndJSONFailures(t *testing.T) {
	for _, test := range []struct {
		name   string
		status int
		body   []byte
		fail   bool
	}{
		{"http", http.StatusBadGateway, []byte("unavailable"), true},
		{"gzip", http.StatusOK, []byte{0x1f, 0x8b, 0}, true},
		{"JSON", http.StatusOK, []byte("broken"), true},
		{"live", http.StatusOK, []byte(`{"value":8}`), false},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("ETag", "next")
				w.WriteHeader(test.status)
				_, _ = w.Write(test.body)
			}))
			defer server.Close()
			feed := &dataTaipeiFeed{client: resty.New().SetBaseURL(server.URL), city: "Taipei", etag: map[string]string{}}
			var out map[string]int
			changed, err := feed.getEnvelope(context.Background(), "GetBusData", &out)
			if (err != nil) != test.fail || changed == test.fail {
				t.Fatalf("response = %v,%v", changed, err)
			}
			if test.fail && feed.etag["GetBusData"] != "" {
				t.Fatal("failed response committed marker")
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	feed := &dataTaipeiFeed{client: resty.New().SetBaseURL("http://127.0.0.1:1"), etag: map[string]string{}}
	if changed, err := feed.getEnvelope(ctx, "GetSpecTimeTable", nil); changed || err == nil {
		t.Fatalf("cancelled request = %v,%v", changed, err)
	}
}
