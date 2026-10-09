package shared

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"golang.org/x/sync/singleflight"
)

// TDX endpoints and token lifetime.
const (
	_tdxBasicBaseURL = "https://tdx.transportdata.tw/api/basic"
	_tdxTokenURL     = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
	_tdxTokenTTL     = 6 * time.Hour
)

type TDXStore interface {
	Get(ctx context.Context, key string) (string, error)
	Set(ctx context.Context, key, value string, ttl time.Duration) error
	Del(ctx context.Context, keys ...string) error
}

// RedisTDXStore adapts *redis.Client to TDXStore, translating a missing key
// (redis.Nil) into an empty value so the client's cold-cache handling stays in
// one place.
type RedisTDXStore struct {
	RC *redis.Client
}

// Get returns the cached value, or "" when the key is absent.
func (s RedisTDXStore) Get(ctx context.Context, key string) (string, error) {
	v, err := s.RC.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil
	}
	return v, err
}

// Set writes value under key with the given TTL (0 = no expiry).
func (s RedisTDXStore) Set(ctx context.Context, key, value string, ttl time.Duration) error {
	return s.RC.Set(ctx, key, value, ttl).Err()
}

// Del removes the given keys.
func (s RedisTDXStore) Del(ctx context.Context, keys ...string) error {
	return s.RC.Del(ctx, keys...).Err()
}

type TDXConfig struct {
	Store         TDXStore
	IMSKey        func(name string) string
	SinceFallback func(name string) string
	BaseURL       string
	Tap           TDXTap
}

type TDXTap func(name string) io.WriteCloser

// TDXClient performs authenticated TDX requests. The zero value is not usable;
// construct one with NewTDXClient.
type TDXClient struct {
	http          *resty.Client
	tokenHTTP     *http.Client
	store         TDXStore
	imsKey        func(name string) string
	sinceFallback func(name string) string
	tap           TDXTap
	tokenRefresh  singleflight.Group
	maxRetries    int
	retryWait     time.Duration
	retryMaxWait  time.Duration
	// tokenURL is the OAuth token endpoint. It defaults to _tdxTokenURL and is a
	// field only so unit tests can point the client_credentials exchange at an
	// httptest server; production never overrides it.
	tokenURL string
}

func NewTDXClient(cfg TDXConfig) *TDXClient {
	base := cfg.BaseURL
	if base == "" {
		base = _tdxBasicBaseURL
	}
	c := &TDXClient{
		store:         cfg.Store,
		imsKey:        cfg.IMSKey,
		sinceFallback: cfg.SinceFallback,
		tap:           cfg.Tap,
		tokenURL:      _tdxTokenURL,
		tokenHTTP:     &http.Client{Timeout: 30 * time.Second},
		maxRetries:    5,
		retryWait:     time.Second,
		retryMaxWait:  5 * time.Second,
	}
	c.http = resty.New().
		SetBaseURL(base).
		SetHeader("Content-Type", "application/json").
		SetHeader("Accept-Encoding", "gzip").
		SetDoNotParseResponse(true).
		SetTimeout(30 * time.Second).
		OnBeforeRequest(func(_ *resty.Client, req *resty.Request) error {
			token, err := c.Token(req.Context())
			if err != nil {
				return &TDXAuthError{Err: err}
			}
			req.SetAuthToken(token)
			return nil
		})
	return c
}

// TDXAuthError marks failures from the shared token/cache hook. Callers with
// their own retry policy (such as MaaS) must not retry these non-transport
// failures.
type TDXAuthError struct {
	Err error
}

func (e *TDXAuthError) Error() string { return e.Err.Error() }
func (e *TDXAuthError) Unwrap() error { return e.Err }

// IsTDXAuthError reports whether err came from the shared auth hook.
func IsTDXAuthError(err error) bool {
	var authErr *TDXAuthError
	return errors.As(err, &authErr)
}

func (c *TDXClient) NewAuthedClient(baseURL string) *resty.Client {
	return resty.New().
		SetBaseURL(baseURL).
		SetTimeout(30 * time.Second).
		OnBeforeRequest(func(_ *resty.Client, req *resty.Request) error {
			token, err := c.Token(req.Context())
			if err != nil {
				return &TDXAuthError{Err: err}
			}
			req.SetAuthToken(token)
			return nil
		})
}

func (c *TDXClient) Token(ctx context.Context) (string, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if token, err := c.cachedToken(ctx); err != nil || token != "" {
		return token, err
	}
	result := c.tokenRefresh.DoChan("refresh", func() (any, error) {
		// The refresh is shared by every waiter, so it runs on its own context:
		// one caller giving up must not cancel the exchange the others are
		// waiting on. This covers the cache re-check as well as the exchange.
		refreshCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if token, err := c.cachedToken(refreshCtx); err != nil || token != "" {
			return token, err
		}
		return c.exchangeToken(refreshCtx)
	})
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case res := <-result:
		if res.Err != nil {
			return "", res.Err
		}
		token, ok := res.Val.(string)
		if !ok || token == "" {
			return "", errors.New("tdx token exchange returned an empty token")
		}
		return token, nil
	}
}

func (c *TDXClient) cachedToken(ctx context.Context) (string, error) {
	token, err := c.store.Get(ctx, TDXTokenKey)
	if err != nil {
		return "", _oops.Wrapf(err, "read cached TDX token")
	}
	if token != "" {
		return token, nil
	}
	token, err = c.store.Get(ctx, TDXTokenKeyLegacy)
	if err != nil {
		return "", _oops.Wrapf(err, "read legacy cached TDX token")
	}
	return token, nil
}

func (c *TDXClient) exchangeToken(ctx context.Context) (string, error) {
	form := url.Values{
		"grant_type":    {"client_credentials"},
		"client_id":     {os.Getenv("TDX_CLIENT_ID")},
		"client_secret": {os.Getenv("TDX_CLIENT_SECRET")},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", _oops.Wrapf(err, "build TDX token request")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.tokenHTTP.Do(req)
	if err != nil {
		return "", _oops.Wrapf(err, "exchange TDX token")
	}
	body, readErr := io.ReadAll(resp.Body)
	closeErr := resp.Body.Close()
	if readErr != nil || closeErr != nil {
		return "", errors.Join(readErr, closeErr)
	}
	if resp.StatusCode >= http.StatusBadRequest {
		return "", _oops.With("status_code", resp.StatusCode).Errorf("exchange TDX token: status")
	}
	var payload struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", _oops.Wrapf(err, "decode TDX token response")
	}
	if payload.AccessToken == "" {
		return "", errors.New("TDX token response is missing access_token")
	}
	if err := c.store.Set(ctx, TDXTokenKey, payload.AccessToken, _tdxTokenTTL); err != nil {
		return "", _oops.Wrapf(err, "cache TDX token")
	}
	return payload.AccessToken, nil
}

// since resolves the If-Modified-Since value for name: the cached marker, or the
// SinceFallback (a DB-derived timestamp) when the cache is cold. A nil fallback
// or an empty cache with no fallback yields "" (fetch everything).
func (c *TDXClient) since(ctx context.Context, name string) (string, error) {
	v, err := c.store.Get(ctx, c.imsKey(name))
	if err != nil {
		return "", _oops.With("name", name).Wrapf(err, "read TDX marker")
	}
	if v == "" && c.sinceFallback != nil {
		v = c.sinceFallback(name)
	}
	return v, nil
}

func drainAndCloseResponse(resp *resty.Response) error {
	if resp == nil || resp.RawResponse == nil || resp.RawResponse.Body == nil {
		return nil
	}
	_, readErr := io.Copy(io.Discard, resp.RawResponse.Body)
	return errors.Join(readErr, resp.RawResponse.Body.Close())
}

func (c *TDXClient) retryDecision(resp *resty.Response, requestErr error) (bool, error) {
	if requestErr != nil {
		if errors.Is(requestErr, context.Canceled) || errors.Is(requestErr, context.DeadlineExceeded) || IsTDXAuthError(requestErr) {
			return false, nil
		}
		return true, nil
	}
	if resp == nil {
		return false, nil
	}
	switch resp.StatusCode() {
	case http.StatusUnauthorized:
		if err := c.store.Del(resp.Request.Context(), TDXTokenKey, TDXTokenKeyLegacy); err != nil {
			return false, _oops.Wrapf(err, "invalidate rejected TDX token")
		}
		return true, nil
	case http.StatusTooManyRequests:
		return true, nil
	default:
		return false, nil
	}
}

func (c *TDXClient) retryDelay(attempt int) time.Duration {
	delay := c.retryWait
	for i := 0; i < attempt && delay < c.retryMaxWait; i++ {
		if delay > c.retryMaxWait/2 {
			return c.retryMaxWait
		}
		delay *= 2
	}
	if delay > c.retryMaxWait {
		return c.retryMaxWait
	}
	return delay
}

// get performs bounded retries while retaining ownership of every streaming
// response body. Intermediate bodies are drained and closed before another
// attempt; final bodies remain owned by Get/GetInto.
func (c *TDXClient) get(ctx context.Context, url, marker string) (*resty.Response, error) {
	for attempt := 0; ; attempt++ {
		resp, requestErr := c.http.R().
			SetContext(ctx).
			SetHeader("If-Modified-Since", marker).
			Get(url)
		retry, decisionErr := c.retryDecision(resp, requestErr)
		if decisionErr != nil {
			return nil, errors.Join(decisionErr, drainAndCloseResponse(resp))
		}
		if !retry {
			if requestErr != nil {
				return nil, errors.Join(requestErr, drainAndCloseResponse(resp))
			}
			return resp, nil
		}
		if attempt >= c.maxRetries {
			if requestErr != nil {
				return nil, errors.Join(requestErr, drainAndCloseResponse(resp))
			}
			return resp, nil
		}
		if err := drainAndCloseResponse(resp); err != nil {
			return nil, err
		}
		delay := c.retryDelay(attempt)
		if delay <= 0 {
			continue
		}
		timer := time.NewTimer(delay)
		select {
		case <-timer.C:
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return nil, ctx.Err()
		}
	}
}

type TDXFetch struct {
	Decoder    *json.Decoder
	Modified   bool
	Ack        func() error
	Close      func() error
	Invalidate func() error
}

type tdxResponseBody struct {
	io.Reader

	close func() error
}

func (b *tdxResponseBody) Close() error {
	_, readErr := io.Copy(io.Discard, b.Reader)
	return errors.Join(readErr, b.close())
}

func decodedTDXBody(resp *resty.Response) (io.ReadCloser, error) {
	raw := resp.RawResponse.Body
	switch strings.ToLower(strings.TrimSpace(resp.Header().Get("Content-Encoding"))) {
	case "", "identity":
		return &tdxResponseBody{Reader: raw, close: raw.Close}, nil
	case "gzip":
		reader, err := gzip.NewReader(raw)
		if err != nil {
			return nil, errors.Join(err, drainAndCloseResponse(resp))
		}
		return &tdxResponseBody{
			Reader: reader,
			close: func() error {
				return errors.Join(reader.Close(), raw.Close())
			},
		}, nil
	default:
		return nil, errors.Join(
			_oops.With("resp", resp.Header().Get("Content-Encoding")).Errorf("unsupported TDX content encoding"),
			drainAndCloseResponse(resp),
		)
	}
}

func tappedBody(body io.ReadCloser, tap TDXTap, name string) io.ReadCloser {
	if tap == nil {
		return body
	}
	sink := tap(name)
	if sink == nil {
		return body
	}
	return &tappedReadCloser{Reader: io.TeeReader(body, sink), body: body, sink: sink}
}

// tappedReadCloser closes the sink before the body, so the sink sees every byte
// the body still had buffered — tdxResponseBody.Close drains the remainder, and
// that drain feeds the tee.
type tappedReadCloser struct {
	io.Reader

	body io.ReadCloser
	sink io.WriteCloser
}

func (t *tappedReadCloser) Close() error {
	// Drain first: an early return by the decoder would otherwise leave the tail
	// of the payload unobserved, producing a truncated archive that still looks
	// like a complete one.
	_, _ = io.Copy(io.Discard, t.Reader)
	_ = t.sink.Close()
	return t.body.Close()
}

func noopTDXFetch(invalidate func() error) *TDXFetch {
	return &TDXFetch{
		Ack:        func() error { return nil },
		Close:      func() error { return nil },
		Invalidate: invalidate,
	}
}

// Get is the streaming conditional GET. A successful response does not advance
// its marker until the returned fetch's Ack is called. A 304 returns a
// Modified=false fetch with safe no-op Ack and Close functions.
func (c *TDXClient) Get(ctx context.Context, url, name string) (*TDXFetch, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	marker, err := c.since(ctx, name)
	if err != nil {
		return nil, err
	}
	resp, err := c.get(ctx, url, marker)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode() == http.StatusNotModified {
		if cerr := drainAndCloseResponse(resp); cerr != nil {
			return nil, cerr
		}
		zap.S().Infow("not modified", "component", "tdx", "action", "fetch", "event", "not_modified", "name", name)
		return noopTDXFetch(func() error {
			if err := c.store.Del(ctx, c.imsKey(name)); err != nil {
				return _oops.With("name", name).Wrapf(err, "invalidate TDX marker")
			}
			return nil
		}), nil
	}
	if resp.StatusCode() >= http.StatusBadRequest {
		statusErr := &TDXStatusError{Name: name, Status: resp.StatusCode()}
		return nil, errors.Join(statusErr, drainAndCloseResponse(resp))
	}
	responseMarker := strings.TrimSpace(resp.Header().Get("Last-Modified"))
	if responseMarker == "" {
		return nil, errors.Join(
			_oops.With("name", name).Errorf("tdx: successful response missing Last-Modified"),
			drainAndCloseResponse(resp),
		)
	}
	body, err := decodedTDXBody(resp)
	if err != nil {
		return nil, err
	}
	body = tappedBody(body, c.tap, name)
	return &TDXFetch{
		Decoder:  json.NewDecoder(body),
		Modified: true,
		Ack: func() error {
			if err := c.store.Set(ctx, c.imsKey(name), responseMarker, 0); err != nil {
				return _oops.With("name", name).Wrapf(err, "ack TDX marker")
			}
			return nil
		},
		Close: body.Close,
		Invalidate: func() error {
			if err := c.store.Del(ctx, c.imsKey(name)); err != nil {
				return _oops.With("name", name).Wrapf(err, "invalidate TDX marker")
			}
			return nil
		},
	}, nil
}

type TDXIntoCommit struct {
	Body   io.ReadSeeker
	Marker string
}

type TDXIntoResult struct {
	Modified   bool
	Marker     string
	Invalidate func() error
}

func (c *TDXClient) GetInto(ctx context.Context, url, name string, commit func(TDXIntoCommit) error) (result TDXIntoResult, err error) {
	if ctx == nil {
		ctx = context.Background()
	}
	marker, err := c.since(ctx, name)
	if err != nil {
		return result, err
	}
	invalidate := func() error {
		if err := c.store.Del(ctx, c.imsKey(name)); err != nil {
			return _oops.With("name", name).Wrapf(err, "invalidate TDX marker")
		}
		return nil
	}
	resp, err := c.get(ctx, url, marker)
	if err != nil {
		return result, err
	}
	if resp.StatusCode() == http.StatusNotModified {
		if cerr := drainAndCloseResponse(resp); cerr != nil {
			return result, cerr
		}
		zap.S().Infow("not modified", "component", "tdx", "action", "fetch", "event", "not_modified", "name", name)
		return TDXIntoResult{Marker: marker, Invalidate: invalidate}, nil
	}
	if resp.StatusCode() >= http.StatusBadRequest {
		statusErr := &TDXStatusError{Name: name, Status: resp.StatusCode()}
		return result, errors.Join(statusErr, drainAndCloseResponse(resp))
	}
	responseMarker := strings.TrimSpace(resp.Header().Get("Last-Modified"))
	if responseMarker == "" {
		return result, errors.Join(
			_oops.With("name", name).Errorf("tdx: successful response missing Last-Modified"),
			drainAndCloseResponse(resp),
		)
	}
	result = TDXIntoResult{Modified: true, Marker: responseMarker, Invalidate: invalidate}
	responseBody, err := decodedTDXBody(resp)
	if err != nil {
		return result, err
	}
	spool, err := os.CreateTemp("", "tdx-response-*.json")
	if err != nil {
		return result, errors.Join(_oops.Wrapf(err, "create TDX response spool"), responseBody.Close())
	}
	spoolName := spool.Name()
	spoolOpen := true
	spoolPresent := true
	defer func() {
		if spoolOpen {
			err = errors.Join(err, spool.Close())
		}
		if spoolPresent {
			err = errors.Join(err, os.Remove(spoolName))
		}
	}()
	_, copyErr := io.Copy(spool, responseBody)
	if closeErr := responseBody.Close(); copyErr != nil || closeErr != nil {
		return result, errors.Join(copyErr, closeErr)
	}
	if _, err := spool.Seek(0, io.SeekStart); err != nil {
		return result, _oops.Wrapf(err, "rewind TDX response spool")
	}
	if commit != nil {
		if cerr := commit(TDXIntoCommit{Body: spool, Marker: responseMarker}); cerr != nil {
			return result, cerr
		}
	}
	if closeErr := spool.Close(); closeErr != nil {
		return result, _oops.Wrapf(closeErr, "close TDX response spool")
	}
	spoolOpen = false
	if removeErr := os.Remove(spoolName); removeErr != nil {
		return result, _oops.Wrapf(removeErr, "remove TDX response spool")
	}
	spoolPresent = false
	return result, c.cacheIMS(ctx, name, responseMarker)
}

// cacheIMS stores the response's Last-Modified header under name's IMS key so the
// next request can send it as If-Modified-Since.
func (c *TDXClient) cacheIMS(ctx context.Context, name, marker string) error {
	if err := c.store.Set(ctx, c.imsKey(name), marker, 0); err != nil {
		return _oops.With("name", name).Wrapf(err, "cache TDX marker")
	}
	return nil
}

// TDXStatusError reports a non-success TDX HTTP status (>=400). It is returned by
// Get/GetInto so callers can distinguish an upstream error from a decode error.
type TDXStatusError struct {
	Name   string
	Status int
}

func (e *TDXStatusError) Error() string {
	return fmt.Sprintf("tdx %s: status %d", e.Name, e.Status)
}
