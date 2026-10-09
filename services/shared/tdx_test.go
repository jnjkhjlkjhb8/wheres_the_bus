package shared

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// memTDXStore is an in-memory TDXStore that records deletes, so tests can assert
// the token cache, the IMS marker, and the 401 dual-delete without a live Redis.
type memTDXStore struct {
	mu     sync.Mutex
	data   map[string]string
	dels   [][]string
	setErr error
	getErr map[string]error
}

func TestGetIntoStreamsWithoutFullBodyBuffer(t *testing.T) {
	const payload = `[{"id":1},{"id":2}]`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = io.WriteString(w, payload)
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	var got string
	var spoolName string
	result, err := c.GetInto(context.Background(), "/x", "thing", func(commit TDXIntoCommit) error {
		body := commit.Body
		spool, ok := body.(*os.File)
		if !ok {
			t.Fatalf("commit body type = %T, want disk-backed *os.File", body)
		}
		spoolName = spool.Name()
		b, err := io.ReadAll(body)
		if err != nil {
			return err
		}
		got = string(b)
		_, err = body.Seek(0, io.SeekStart)
		return err
	})
	if err != nil || !result.Modified {
		t.Fatalf("GetInto result=%+v err=%v", result, err)
	}
	if got != payload {
		t.Fatalf("spooled payload = %q, want %q", got, payload)
	}
	if _, err := os.Stat(spoolName); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("temporary spool still exists at %q: %v", spoolName, err)
	}
}

func TestGetIntoHonorsCanceledContext(t *testing.T) {
	var hits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = io.WriteString(w, `[]`)
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result, err := c.GetInto(ctx, "/x", "thing", func(TDXIntoCommit) error {
		return errors.New("commit unexpectedly called")
	})
	if result.Modified || !errors.Is(err, context.Canceled) {
		t.Fatalf("GetInto canceled result = %+v, error %v", result, err)
	}
	if hits.Load() != 0 {
		t.Fatalf("canceled GetInto reached upstream %d times", hits.Load())
	}
}

func newMemTDXStore() *memTDXStore { return &memTDXStore{data: map[string]string{}} }

func (m *memTDXStore) Get(_ context.Context, key string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.getErr[key]; err != nil {
		return "", err
	}
	return m.data[key], nil
}

func (m *memTDXStore) Set(_ context.Context, key, value string, _ time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.setErr != nil {
		return m.setErr
	}
	m.data[key] = value
	return nil
}

func (m *memTDXStore) Del(_ context.Context, keys ...string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dels = append(m.dels, keys)
	for _, k := range keys {
		delete(m.data, k)
	}
	return nil
}

func (m *memTDXStore) get(key string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.data[key]
}

func legacyIMSKey(name string) string { return TDXLegacyIMSKey(name) }

// TestTokenRefreshAndCache proves Token does a client_credentials exchange on a
// cold cache, caches the result, and serves the cache on the next call without a
// second exchange.
func TestTokenRefreshAndCache(t *testing.T) {
	var hits int32
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write([]byte(`{"access_token":"tok-123"}`))
	}))
	defer tokenSrv.Close()

	store := newMemTDXStore()
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey})
	c.tokenURL = tokenSrv.URL

	if got, err := c.Token(context.Background()); err != nil || got != "tok-123" {
		t.Fatalf("Token() = %q, %v; want tok-123, nil", got, err)
	}
	if store.get(TDXTokenKey) != "tok-123" {
		t.Fatalf("token not cached under %s: %q", TDXTokenKey, store.get(TDXTokenKey))
	}
	if got, err := c.Token(context.Background()); err != nil || got != "tok-123" {
		t.Fatalf("cached Token() = %q, %v; want tok-123, nil", got, err)
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("token endpoint hit %d times, want 1 (second call must serve cache)", n)
	}
}

// TestGet304LeavesMarker proves a 304 Not-Modified returns modified=false with no
// error and no decoder, and does not touch the cached If-Modified-Since marker.
func TestGet304LeavesMarker(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotModified)
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	store.data[TDXLegacyIMSKey("thing")] = "MARKER-OLD"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})

	fetch, err := c.Get(context.Background(), "/x", "thing")
	if err != nil {
		t.Fatalf("Get on 304 returned error: %v", err)
	}
	if fetch.Modified {
		t.Fatal("Get on 304 reported modified=true")
	}
	if fetch.Decoder != nil {
		t.Fatal("Get on 304 must return nil decoder")
	}
	if err := fetch.Close(); err != nil {
		t.Fatalf("Close on 304 returned error: %v", err)
	}
	if store.get(TDXLegacyIMSKey("thing")) != "MARKER-OLD" {
		t.Fatalf("304 overwrote IMS marker: %q", store.get(TDXLegacyIMSKey("thing")))
	}
	if err := fetch.Invalidate(); err != nil {
		t.Fatalf("Invalidate on 304 returned error: %v", err)
	}
	if got := store.get(TDXLegacyIMSKey("thing")); got != "" {
		t.Fatalf("Invalidate left IMS marker %q, want empty", got)
	}
}

// TestGet4xxDoesNotCacheMarker is the regression guard for the router's old bug:
// a 5xx/4xx must return a TDXStatusError, not decode the error body, and must
// leave the previous If-Modified-Since marker intact.
func TestGet4xxDoesNotCacheMarker(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Last-Modified", "SHOULD-NOT-CACHE")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"boom"}`))
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	store.data[TDXLegacyIMSKey("thing")] = "MARKER-OLD"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})

	fetch, err := c.Get(context.Background(), "/x", "thing")
	var statusErr *TDXStatusError
	if !errors.As(err, &statusErr) {
		t.Fatalf("Get on 500 returned err %v, want *TDXStatusError", err)
	}
	if statusErr.Status != http.StatusInternalServerError {
		t.Fatalf("TDXStatusError.Status = %d, want 500", statusErr.Status)
	}
	if fetch != nil {
		t.Fatal("Get on 500 must return no fetch")
	}
	if store.get(TDXLegacyIMSKey("thing")) != "MARKER-OLD" {
		t.Fatalf("500 cached a bad IMS marker: %q", store.get(TDXLegacyIMSKey("thing")))
	}
}

type trackingResponseBody struct {
	reader   *strings.Reader
	read     int
	closed   int
	closeErr error
}

func newTrackingResponseBody(body string) *trackingResponseBody {
	return &trackingResponseBody{reader: strings.NewReader(body)}
}

func (b *trackingResponseBody) Read(p []byte) (int, error) {
	n, err := b.reader.Read(p)
	b.read += n
	return n, err
}

func (b *trackingResponseBody) Close() error {
	b.closed++
	return b.closeErr
}

type tdxRoundTripFunc func(*http.Request) (*http.Response, error)

func (f tdxRoundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func trackingResponse(req *http.Request, status int, body *trackingResponseBody) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header:     make(http.Header),
		Body:       body,
		Request:    req,
	}
}

func TestRetryDrainsAndClosesIntermediateResponses(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusTooManyRequests} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			first := newTrackingResponseBody("retry response")
			last := newTrackingResponseBody(`[]`)
			var attempts int
			store := newMemTDXStore()
			store.data[TDXTokenKey] = "stale-token"
			client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: "https://tdx.invalid"})
			if status == http.StatusUnauthorized {
				tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
					_, _ = w.Write([]byte(`{"access_token":"fresh-token"}`))
				}))
				defer tokenSrv.Close()
				client.tokenURL = tokenSrv.URL
			}
			client.maxRetries = 1
			client.retryWait = time.Nanosecond
			client.retryMaxWait = time.Nanosecond
			client.http.SetTransport(tdxRoundTripFunc(func(req *http.Request) (*http.Response, error) {
				attempts++
				if attempts == 1 {
					return trackingResponse(req, status, first), nil
				}
				resp := trackingResponse(req, http.StatusOK, last)
				resp.Header.Set("Last-Modified", "MARKER-NEW")
				return resp, nil
			}))

			fetch, err := client.Get(context.Background(), "/x", "thing")
			if err != nil {
				t.Fatalf("Get: %v", err)
			}
			if err := fetch.Close(); err != nil {
				t.Fatalf("Close: %v", err)
			}
			if first.read != len("retry response") || first.closed != 1 {
				t.Fatalf("intermediate body read/close = %d/%d, want %d/1", first.read, first.closed, len("retry response"))
			}
		})
	}
}

func TestFinalErrorResponseIsDrainedAndClosed(t *testing.T) {
	body := newTrackingResponseBody("final rate limit response")
	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: "https://tdx.invalid"})
	client.maxRetries = 0
	client.http.SetTransport(tdxRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		return trackingResponse(req, http.StatusTooManyRequests, body), nil
	}))

	_, err := client.Get(context.Background(), "/x", "thing")
	var statusErr *TDXStatusError
	if !errors.As(err, &statusErr) {
		t.Fatalf("Get error = %v, want TDXStatusError", err)
	}
	if body.read != len("final rate limit response") || body.closed != 1 {
		t.Fatalf("final body read/close = %d/%d, want %d/1", body.read, body.closed, len("final rate limit response"))
	}
}

func TestIntermediateResponseCloseErrorStopsRetry(t *testing.T) {
	closeErr := errors.New("close retry response")
	body := newTrackingResponseBody("retry response")
	body.closeErr = closeErr
	var attempts int
	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: "https://tdx.invalid"})
	client.maxRetries = 1
	client.retryWait = time.Nanosecond
	client.retryMaxWait = time.Nanosecond
	client.http.SetTransport(tdxRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		attempts++
		if attempts == 1 {
			return trackingResponse(req, http.StatusTooManyRequests, body), nil
		}
		return trackingResponse(req, http.StatusOK, newTrackingResponseBody(`[]`)), nil
	}))

	_, err := client.Get(context.Background(), "/x", "thing")
	if !errors.Is(err, closeErr) {
		t.Fatalf("Get error = %v, want %v", err, closeErr)
	}
	if attempts != 1 {
		t.Fatalf("attempts = %d, want 1 after close failure", attempts)
	}
}

// TestGet401ReAuths proves a 401 drops both token keys and retries with a freshly
// exchanged token, so a stale token self-heals on the next attempt.
func TestGet401ReAuths(t *testing.T) {
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"fresh-tok"}`))
	}))
	defer tokenSrv.Close()

	var attempts int32
	apiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt32(&attempts, 1) == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = w.Write([]byte(`[{"ok":true}]`))
	}))
	defer apiSrv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "stale-tok"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: apiSrv.URL})
	c.tokenURL = tokenSrv.URL

	fetch, err := c.Get(context.Background(), "/x", "thing")
	if err != nil {
		t.Fatalf("Get across a 401 retry returned error: %v", err)
	}
	if !fetch.Modified || fetch.Decoder == nil {
		t.Fatal("Get after re-auth must return fresh data")
	}
	if err := fetch.Close(); err != nil {
		t.Fatalf("Close after re-auth: %v", err)
	}
	if n := atomic.LoadInt32(&attempts); n != 2 {
		t.Fatalf("API attempts = %d, want 2 (401 then retry)", n)
	}
	if len(store.dels) == 0 {
		t.Fatal("401 did not delete the token keys")
	}
	sawBothKeys := false
	for _, d := range store.dels {
		if len(d) == 2 && d[0] == TDXTokenKey && d[1] == TDXTokenKeyLegacy {
			sawBothKeys = true
		}
	}
	if !sawBothKeys {
		t.Fatalf("401 delete did not drop both token keys, dels=%v", store.dels)
	}
	if store.get(TDXTokenKey) != "fresh-tok" {
		t.Fatalf("token after re-auth = %q, want fresh-tok", store.get(TDXTokenKey))
	}
}

func TestGetHonorsCanceledContext(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write([]byte(`[]`))
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	started := time.Now()
	fetch, err := c.Get(ctx, "/x", "thing")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Get canceled context error = %v, want context.Canceled", err)
	}
	if fetch != nil {
		t.Fatal("Get canceled context returned a fetch")
	}
	if got := atomic.LoadInt32(&hits); got != 0 {
		t.Fatalf("canceled request reached server %d times, want 0", got)
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("canceled Get took %v, want prompt return", elapsed)
	}
}

func TestGetDoesNotAdvanceMarkerUntilAck(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = w.Write([]byte(`[]`))
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	store.data[TDXLegacyIMSKey("thing")] = "MARKER-OLD"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})

	fetch, err := c.Get(context.Background(), "/x", "thing")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	defer func() {
		if err := fetch.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	}()
	if got := store.get(TDXLegacyIMSKey("thing")); got != "MARKER-OLD" {
		t.Fatalf("marker before Ack = %q, want MARKER-OLD", got)
	}
	if err := fetch.Ack(); err != nil {
		t.Fatalf("Ack: %v", err)
	}
	if got := store.get(TDXLegacyIMSKey("thing")); got != "MARKER-NEW" {
		t.Fatalf("marker after Ack = %q, want MARKER-NEW", got)
	}
}

func TestGetAckReturnsMarkerStoreError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = w.Write([]byte(`[]`))
	}))
	defer srv.Close()

	storeErr := errors.New("redis unavailable")
	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	store.data[TDXLegacyIMSKey("thing")] = "MARKER-OLD"
	store.setErr = storeErr
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})

	fetch, err := c.Get(context.Background(), "/x", "thing")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	defer func() { _ = fetch.Close() }()
	if err := fetch.Ack(); !errors.Is(err, storeErr) {
		t.Fatalf("Ack error = %v, want %v", err, storeErr)
	}
	if got := store.get(TDXLegacyIMSKey("thing")); got != "MARKER-OLD" {
		t.Fatalf("failed Ack changed marker to %q", got)
	}
}

func TestMarkerReadErrorPreventsRequest(t *testing.T) {
	markerErr := errors.New("marker redis unavailable")
	for _, tt := range []struct {
		name string
		call func(*TDXClient) error
	}{
		{name: "Get", call: func(c *TDXClient) error {
			_, err := c.Get(context.Background(), "/x", "thing")
			return err
		}},
		{name: "GetInto", call: func(c *TDXClient) error {
			_, err := c.GetInto(context.Background(), "/x", "thing", func(TDXIntoCommit) error { return nil })
			return err
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var hits int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				atomic.AddInt32(&hits, 1)
				_, _ = w.Write([]byte(`[]`))
			}))
			defer srv.Close()

			store := newMemTDXStore()
			store.data[TDXTokenKey] = "tok"
			store.getErr = map[string]error{TDXLegacyIMSKey("thing"): markerErr}
			client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
			if err := tt.call(client); !errors.Is(err, markerErr) {
				t.Fatalf("error = %v, want %v", err, markerErr)
			}
			if got := atomic.LoadInt32(&hits); got != 0 {
				t.Fatalf("upstream hits = %d, want 0", got)
			}
		})
	}
}

func TestSuccessWithoutLastModifiedFailsClosed(t *testing.T) {
	unexpectedFetch := errors.New("returned a fetch without Last-Modified")
	unexpectedCommit := errors.New("committed a response without Last-Modified")
	for _, tt := range []struct {
		name string
		call func(*TDXClient) error
	}{
		{name: "Get", call: func(c *TDXClient) error {
			fetch, err := c.Get(context.Background(), "/x", "thing")
			if fetch != nil {
				_ = fetch.Close()
				return unexpectedFetch
			}
			return err
		}},
		{name: "GetInto", call: func(c *TDXClient) error {
			committed := false
			_, err := c.GetInto(context.Background(), "/x", "thing", func(TDXIntoCommit) error {
				committed = true
				return nil
			})
			if committed {
				return unexpectedCommit
			}
			return err
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(`[]`))
			}))
			defer srv.Close()

			store := newMemTDXStore()
			store.data[TDXTokenKey] = "tok"
			store.data[TDXLegacyIMSKey("thing")] = "MARKER-OLD"
			client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
			err := tt.call(client)
			if errors.Is(err, unexpectedFetch) || errors.Is(err, unexpectedCommit) {
				t.Fatal(err)
			}
			if err == nil {
				t.Fatal("success without Last-Modified returned nil error")
			}
			if got := store.get(TDXLegacyIMSKey("thing")); got != "MARKER-OLD" {
				t.Fatalf("marker = %q, want MARKER-OLD", got)
			}
		})
	}
}

func TestTokenExchangeHonorsContext(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(started)
		<-release
		_, _ = w.Write([]byte(`{"access_token":"eventual-token"}`))
	}))
	defer tokenSrv.Close()

	store := newMemTDXStore()
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey})
	c.tokenURL = tokenSrv.URL
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := c.Token(ctx)
		done <- err
	}()
	<-started
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Token canceled context error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Token did not return after context cancellation")
	}
	close(release)
	deadline := time.Now().Add(time.Second)
	for store.get(TDXTokenKey) == "" && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
}

func TestTokenRefreshSurvivesFirstCallerCancellation(t *testing.T) {
	var hits int32
	started := make(chan struct{})
	release := make(chan struct{})
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		close(started)
		<-release
		_, _ = w.Write([]byte(`{"access_token":"shared-token"}`))
	}))
	defer tokenSrv.Close()

	c := NewTDXClient(TDXConfig{Store: newMemTDXStore(), IMSKey: legacyIMSKey})
	c.tokenURL = tokenSrv.URL
	firstCtx, cancelFirst := context.WithCancel(context.Background())
	firstDone := make(chan error, 1)
	go func() {
		_, err := c.Token(firstCtx)
		firstDone <- err
	}()
	<-started
	cancelFirst()
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("first caller error = %v, want context.Canceled", err)
	}

	secondDone := make(chan struct {
		token string
		err   error
	}, 1)
	go func() {
		token, err := c.Token(context.Background())
		secondDone <- struct {
			token string
			err   error
		}{token: token, err: err}
	}()
	close(release)
	result := <-secondDone
	if result.err != nil || result.token != "shared-token" {
		t.Fatalf("second caller = %q, %v; want shared-token, nil", result.token, result.err)
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("token endpoint hits = %d, want 1", got)
	}
}

func TestTokenRefreshSingleflight(t *testing.T) {
	const callers = 24
	var hits int32
	release := make(chan struct{})
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		<-release
		_, _ = w.Write([]byte(`{"access_token":"shared-token"}`))
	}))
	defer tokenSrv.Close()

	c := NewTDXClient(TDXConfig{Store: newMemTDXStore(), IMSKey: legacyIMSKey})
	c.tokenURL = tokenSrv.URL
	start := make(chan struct{})
	results := make(chan error, callers)
	for range callers {
		go func() {
			<-start
			token, err := c.Token(context.Background())
			if err == nil && token != "shared-token" {
				err = errors.New("unexpected token " + token)
			}
			results <- err
		}()
	}
	close(start)
	deadline := time.Now().Add(time.Second)
	for atomic.LoadInt32(&hits) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	close(release)
	for i := range callers {
		if err := <-results; err != nil {
			t.Fatalf("Token caller %d: %v", i, err)
		}
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("token endpoint hits = %d, want 1", got)
	}
}

func TestRequestUsesAcceptEncoding(t *testing.T) {
	var acceptEncoding, contentEncoding string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		acceptEncoding = r.Header.Get("Accept-Encoding")
		contentEncoding = r.Header.Get("Content-Encoding")
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = w.Write([]byte(`[]`))
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	fetch, err := c.Get(context.Background(), "/x", "thing")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if err := fetch.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if acceptEncoding != "gzip" {
		t.Fatalf("Accept-Encoding = %q, want gzip", acceptEncoding)
	}
	if contentEncoding != "" {
		t.Fatalf("Content-Encoding = %q, want empty", contentEncoding)
	}
}

func TestGetDecodesAdvertisedEncoding(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Accept-Encoding"); got != "gzip" {
			t.Errorf("Accept-Encoding = %q, want gzip", got)
		}
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Last-Modified", "MARKER-NEW")
		zw := gzip.NewWriter(w)
		_, _ = zw.Write([]byte(`[{"ok":true}]`))
		_ = zw.Close()
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	fetch, err := c.Get(context.Background(), "/x", "thing")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	defer func() { _ = fetch.Close() }()
	var payload []struct {
		OK bool `json:"ok"`
	}
	if err := fetch.Decoder.Decode(&payload); err != nil {
		t.Fatalf("decode compressed payload: %v", err)
	}
	if len(payload) != 1 || !payload[0].OK {
		t.Fatalf("decoded payload = %+v", payload)
	}
}

func TestGetCloseValidatesUnreadGzip(t *testing.T) {
	var compressed bytes.Buffer
	zw := gzip.NewWriter(&compressed)
	_, _ = zw.Write([]byte(`[1,2,3]`))
	_ = zw.Close()
	corrupt := append([]byte(nil), compressed.Bytes()...)
	corrupt[len(corrupt)-1] ^= 0xff

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = w.Write(corrupt)
	}))
	defer srv.Close()

	store := newMemTDXStore()
	store.data[TDXTokenKey] = "tok"
	c := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	fetch, err := c.Get(context.Background(), "/x", "thing")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if err := fetch.Close(); err == nil {
		t.Fatal("Close on unread corrupt gzip returned nil error")
	}
}

// TestGetIntoCommitsBeforeMarker proves GetInto advances the IMS marker only
// after commit succeeds, and leaves it untouched when commit fails, so a failed
// durable write refetches next run instead of being masked by a later 304.
func TestGetIntoCommitsBeforeMarker(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Last-Modified", "MARKER-NEW")
		_, _ = w.Write([]byte(`[1,2,3]`))
	}))
	defer srv.Close()

	commitErr := errors.New("commit failed")

	// Commit fails: marker must stay empty.
	failStore := newMemTDXStore()
	failStore.data[TDXTokenKey] = "tok"
	fc := NewTDXClient(TDXConfig{Store: failStore, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	result, err := fc.GetInto(context.Background(), "/x", "thing", func(TDXIntoCommit) error { return commitErr })
	if !errors.Is(err, commitErr) {
		t.Fatalf("GetInto returned err %v, want commitErr", err)
	}
	if !result.Modified {
		t.Fatal("GetInto with fresh data must report modified=true even on commit failure")
	}
	if failStore.get(TDXLegacyIMSKey("thing")) != "" {
		t.Fatalf("failed commit advanced the IMS marker: %q", failStore.get(TDXLegacyIMSKey("thing")))
	}

	// Commit succeeds: marker advances and commit sees the body.
	okStore := newMemTDXStore()
	okStore.data[TDXTokenKey] = "tok"
	oc := NewTDXClient(TDXConfig{Store: okStore, IMSKey: legacyIMSKey, BaseURL: srv.URL})
	var seen string
	result, err = oc.GetInto(context.Background(), "/x", "thing", func(commit TDXIntoCommit) error {
		b, readErr := io.ReadAll(commit.Body)
		seen = string(b)
		return readErr
	})
	if err != nil || !result.Modified {
		t.Fatalf("GetInto ok path: result=%+v err=%v", result, err)
	}
	if seen != "[1,2,3]" {
		t.Fatalf("commit body = %q, want [1,2,3]", seen)
	}
	if okStore.get(TDXLegacyIMSKey("thing")) != "MARKER-NEW" {
		t.Fatalf("successful commit did not advance IMS marker: %q", okStore.get(TDXLegacyIMSKey("thing")))
	}
}

func TestGetIntoReturnsTypedMarkerAndInvalidator(t *testing.T) {
	t.Run("modified response exposes response marker to commit", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Last-Modified", "MARKER-NEW")
			_, _ = io.WriteString(w, `[]`)
		}))
		defer srv.Close()

		store := newMemTDXStore()
		store.data[TDXTokenKey] = "tok"
		client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
		var commitMarker string
		result, err := client.GetInto(context.Background(), "/x", "thing", func(commit TDXIntoCommit) error {
			commitMarker = commit.Marker
			return nil
		})
		if err != nil {
			t.Fatalf("GetInto: %v", err)
		}
		if !result.Modified || result.Marker != "MARKER-NEW" || commitMarker != "MARKER-NEW" {
			t.Fatalf("result=%+v commit marker=%q", result, commitMarker)
		}
		if result.Invalidate == nil {
			t.Fatal("modified result has nil invalidator")
		}
	})

	t.Run("not modified response exposes conditional marker and invalidator", func(t *testing.T) {
		var requestMarker string
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requestMarker = r.Header.Get("If-Modified-Since")
			w.WriteHeader(http.StatusNotModified)
		}))
		defer srv.Close()

		store := newMemTDXStore()
		store.data[TDXTokenKey] = "tok"
		store.data[TDXLegacyIMSKey("thing")] = "MARKER-OLD"
		client := NewTDXClient(TDXConfig{Store: store, IMSKey: legacyIMSKey, BaseURL: srv.URL})
		result, err := client.GetInto(context.Background(), "/x", "thing", func(TDXIntoCommit) error {
			return errors.New("commit unexpectedly called")
		})
		if err != nil {
			t.Fatalf("GetInto: %v", err)
		}
		if result.Modified || result.Marker != "MARKER-OLD" || requestMarker != "MARKER-OLD" {
			t.Fatalf("result=%+v request marker=%q", result, requestMarker)
		}
		if result.Invalidate == nil {
			t.Fatal("304 result has nil invalidator")
		}
		if err := result.Invalidate(); err != nil {
			t.Fatalf("invalidate: %v", err)
		}
		if got := store.get(TDXLegacyIMSKey("thing")); got != "" {
			t.Fatalf("marker after invalidate = %q, want empty", got)
		}
	})
}
