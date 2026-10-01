package shared

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-resty/resty/v2"
)

func TestGetTrainInfoRequestAndParse(t *testing.T) {
	var gotBody, gotContentType string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)
		gotContentType = r.Header.Get("Content-Type")
		// Object embedded before a trailing SOAP envelope, as the real service
		// returns it.
		_, _ = io.WriteString(w, `{"TrainId":"1109","TripId":"201","StnName":"忠孝新生站","CountdownTime":"03:39","DestName":"BL18","UpdateTime":"2026/7/22 下午 06:17:27"}<soap:Envelope/>`)
	}))
	defer srv.Close()

	client := newTRTCTrainInfoClientWithHTTP(resty.New(), srv.URL, "user", "pass")
	info, ok, err := client.GetTrainInfo(context.Background(), "1021")
	if err != nil {
		t.Fatalf("GetTrainInfo: %v", err)
	}
	if !ok {
		t.Fatal("expected a reading")
	}
	if info.TripID != "201" || info.StnName != "忠孝新生站" || info.CountdownTime != "03:39" {
		t.Errorf("parsed = %+v", info)
	}
	if gotContentType != "application/soap+xml; charset=utf-8" {
		t.Errorf("Content-Type = %q", gotContentType)
	}
	if strings.Contains(gotBody, "tempuri.org") || strings.Contains(gotBody, "<GetTrainInfo xmlns") {
		t.Errorf("GetTrainInfo element must carry no xmlns, body = %q", gotBody)
	}
	if !strings.Contains(gotBody, "<GetTrainInfo><carID>1021</carID>") {
		t.Errorf("unexpected body shape = %q", gotBody)
	}
	if !strings.Contains(gotBody, "<username>user</username>") || !strings.Contains(gotBody, "<password>pass</password>") {
		t.Errorf("credentials not in lowercase username/password elements, body = %q", gotBody)
	}
}

// An empty result (no JSON object) is an expected caller-facing outcome —
// unknown/invalid carID — not an error.
func TestGetTrainInfoEmptyResult(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `<?xml version="1.0"?><soap:Envelope><soap:Body></soap:Body></soap:Envelope>`)
	}))
	defer srv.Close()

	client := newTRTCTrainInfoClientWithHTTP(resty.New(), srv.URL, "user", "pass")
	info, ok, err := client.GetTrainInfo(context.Background(), "121")
	if err != nil {
		t.Fatalf("GetTrainInfo: %v", err)
	}
	if ok || info != nil {
		t.Errorf("expected empty result, got ok=%v info=%+v", ok, info)
	}
}

// Empty credentials skip the request entirely (zero requests), mirroring the
// trtcEta env-gating convention.
func TestGetTrainInfoNoCredentials(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true }))
	defer srv.Close()

	client := newTRTCTrainInfoClientWithHTTP(resty.New(), srv.URL, "", "")
	_, ok, err := client.GetTrainInfo(context.Background(), "1021")
	if err != nil || ok {
		t.Fatalf("GetTrainInfo with no creds = ok:%v err:%v", ok, err)
	}
	if called {
		t.Error("expected zero requests with empty credentials")
	}
}

func TestExtractJSONObject(t *testing.T) {
	tests := []struct {
		in   string
		want string
		ok   bool
	}{
		{`{"a":1}`, `{"a":1}`, true},
		{`prefix{"a":1}suffix`, `{"a":1}`, true},
		{`no json here`, "", false},
		{`}{`, "", false},
	}
	for _, tt := range tests {
		got, ok := extractJSONObject([]byte(tt.in))
		if ok != tt.ok || string(got) != tt.want {
			t.Errorf("extractJSONObject(%q) = %q,%v want %q,%v", tt.in, got, ok, tt.want, tt.ok)
		}
	}
}
