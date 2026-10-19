package shared

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/sync/singleflight"
)

func TestTDXRetryDelayCapsExponentialBackoff(t *testing.T) {
	client := &TDXClient{retryWait: time.Second, retryMaxWait: 5 * time.Second}
	for attempt, want := range []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 5 * time.Second, 5 * time.Second} {
		if got := client.retryDelay(attempt); got != want {
			t.Fatalf("delay attempt%d=%v want=%v", attempt, got, want)
		}
	}
	client.retryWait = 6 * time.Second
	if got := client.retryDelay(0); got != 5*time.Second {
		t.Fatal(got)
	}
}

func TestTDXTokenResultValidation(t *testing.T) {
	want := errors.New("exchange failed")
	for _, tc := range []struct {
		result singleflight.Result
		token  string
		err    bool
	}{{singleflight.Result{Val: "token"}, "token", false}, {singleflight.Result{Err: want}, "", true}, {singleflight.Result{Val: 42}, "", true}, {singleflight.Result{Val: ""}, "", true}} {
		results := make(chan singleflight.Result, 1)
		results <- tc.result
		token, err := waitForToken(context.Background(), results)
		if token != tc.token || (err != nil) != tc.err {
			t.Errorf("token=%q error=%v", token, err)
		}
		if tc.result.Err != nil && !errors.Is(err, want) {
			t.Fatalf("exchange cause lost: %v", err)
		}
	}
	if contextOrBackground(nil) == nil { //nolint:staticcheck // This exercises the nil-context fallback.
		t.Fatal("nil default context")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if contextOrBackground(ctx) != ctx {
		t.Fatal("caller context replaced")
	}
	if _, err := waitForToken(ctx, make(chan singleflight.Result)); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if err := waitTDXRetry(ctx, time.Hour); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if err := waitTDXRetry(ctx, 0); err != nil {
		t.Fatal(err)
	}
	if err := waitTDXRetry(context.Background(), time.Millisecond); err != nil {
		t.Fatal(err)
	}
}

type failingCloseBody struct {
	io.Reader
	err error
}

func (b failingCloseBody) Close() error { return b.err }

func TestReadAndCloseTokenPreservesBodyAndCloseFailure(t *testing.T) {
	want := errors.New("close failed")
	body, err := readAndCloseToken(failingCloseBody{strings.NewReader("token"), want})
	if string(body) != "token" || !errors.Is(err, want) {
		t.Fatalf("body=%q error=%v", body, err)
	}
	for _, body := range []string{`{bad}`, `{}`, `{"access_token":""}`} {
		if token, err := decodeToken([]byte(body)); token != "" || err == nil {
			t.Errorf("invalid token %q=%q,%v", body, token, err)
		}
	}
	if token, err := decodeToken([]byte(`{"access_token":"valid"}`)); token != "valid" || err != nil {
		t.Fatalf("token=%q error=%v", token, err)
	}
}

func TestTDXSpoolCleanupAndFailureStages(t *testing.T) {
	want := errors.New("body close failed")
	spool, err := os.CreateTemp(t.TempDir(), "response")
	if err != nil {
		t.Fatal(err)
	}
	if err := prepareTDXSpool(spool, failingCloseBody{strings.NewReader("body"), want}); !errors.Is(err, want) {
		t.Fatalf("close cause=%v", err)
	}
	state := tdxSpool{File: spool, open: true, present: true}
	if err := state.cleanup(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(spool.Name()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("spool remains: %v", err)
	}
	if err := prepareTDXSpool(spool, io.NopCloser(strings.NewReader("body"))); err == nil {
		t.Fatal("COPY into closed spool accepted")
	}
	if err := state.closeAndRemove(); err == nil {
		t.Fatal("closed spool accepted")
	}
	spool, err = os.CreateTemp(t.TempDir(), "removed")
	if err != nil {
		t.Fatal(err)
	}
	state = tdxSpool{File: spool, open: true, present: true}
	if err := os.Remove(spool.Name()); err != nil {
		t.Fatal(err)
	}
	if err := state.closeAndRemove(); err == nil || state.open {
		t.Fatalf("missing spool removal error=%v open=%v", err, state.open)
	}
}

func TestTDXTokenExchangeErrorsAndRequestContract(t *testing.T) {
	t.Setenv("TDX_CLIENT_ID", "test-client")
	t.Setenv("TDX_CLIENT_SECRET", "test-secret")
	storeErr := errors.New("cache write failed")
	for _, tc := range []struct {
		status   int
		body     string
		storeErr error
	}{
		{http.StatusBadRequest, `denied`, nil},
		{http.StatusOK, `{bad}`, nil},
		{http.StatusOK, `{}`, nil},
		{http.StatusOK, `{"access_token":"token"}`, storeErr},
	} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
			if err := request.ParseForm(); err != nil {
				t.Error(err)
			}
			if request.Method != http.MethodPost || request.Header.Get("Content-Type") != "application/x-www-form-urlencoded" || request.Form.Get("grant_type") != "client_credentials" || request.Form.Get("client_id") != "test-client" || request.Form.Get("client_secret") != "test-secret" {
				t.Error("invalid client credentials request")
			}
			w.WriteHeader(tc.status)
			_, _ = io.WriteString(w, tc.body)
		}))
		store := newMemTDXStore()
		store.setErr = tc.storeErr
		client := NewTDXClient(TDXConfig{Store: store})
		client.tokenURL = server.URL
		token, err := client.exchangeToken(context.Background())
		server.Close()
		if token != "" || err == nil || tc.storeErr != nil && !errors.Is(err, tc.storeErr) {
			t.Fatalf("failed exchange token=%q error=%v", token, err)
		}
	}
	client := NewTDXClient(TDXConfig{Store: newMemTDXStore()})
	client.tokenURL = "://bad"
	if _, err := client.exchangeToken(context.Background()); err == nil {
		t.Fatal("invalid token URL accepted")
	}
	want := errors.New("transport failed")
	client.tokenURL = "http://test.invalid/token"
	client.tokenHTTP = &http.Client{Transport: tdxRoundTripFunc(func(*http.Request) (*http.Response, error) { return nil, want })}
	if _, err := client.exchangeToken(context.Background()); !errors.Is(err, want) {
		t.Fatalf("transport error=%v", err)
	}
	client.tokenHTTP = &http.Client{Transport: tdxRoundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: failingCloseBody{strings.NewReader(`{"access_token":"token"}`), want}}, nil
	})}
	if _, err := client.exchangeToken(context.Background()); !errors.Is(err, want) {
		t.Fatalf("close error=%v", err)
	}
}
