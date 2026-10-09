package main

import (
	"context"
	"crypto"
	cryptorand "crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"
	"github.com/gin-gonic/gin"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
)

func testKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(cryptorand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func verifyJWT(t *testing.T, token string, pub *rsa.PublicKey) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected 3 segments, got %d", len(parts))
	}
	h := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, h[:], sig); err != nil {
		t.Fatalf("signature invalid: %v", err)
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	claims := map[string]any{}
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatal(err)
	}
	return claims
}

func TestSignRS256RoundTrip(t *testing.T) {
	key := testKey(t)
	token, err := signRS256(key, map[string]any{"sub": "x"})
	if err != nil {
		t.Fatal(err)
	}
	claims := verifyJWT(t, token, &key.PublicKey)
	if claims["sub"] != "x" {
		t.Fatalf("unexpected claims: %v", claims)
	}
}

func TestHandleTokenIssuesValidJWT(t *testing.T) {
	key := testKey(t)
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/api/token/powersync", handleToken(key))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/token/powersync", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	var body struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	claims := verifyJWT(t, body.Token, &key.PublicKey)
	if claims["aud"] != "powersync" || claims["sub"] != _powersyncAnonymousSubject {
		t.Fatalf("unexpected claims: %v", claims)
	}
	exp := int64(claims["exp"].(float64))
	iat := int64(claims["iat"].(float64))
	if exp <= iat || exp <= time.Now().Unix() {
		t.Fatalf("bad exp/iat: exp=%d iat=%d", exp, iat)
	}
	if got, want := exp-iat, int64(_powersyncTokenTTL.Seconds()); got != want {
		t.Fatalf("token TTL = %ds, want %ds", got, want)
	}
}

// A caller that sends X-Install-Id gets it back as the "sub" claim, so a
// leaked/observed token can be traced to the installation that requested it.
func TestHandleTokenBindsInstallationID(t *testing.T) {
	key := testKey(t)
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/api/token/powersync", handleToken(key))
	req := httptest.NewRequest(http.MethodGet, "/api/token/powersync", nil)
	req.Header.Set("X-Install-Id", "install-abc-123")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	var body struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	claims := verifyJWT(t, body.Token, &key.PublicKey)
	if claims["sub"] != "install-abc-123" {
		t.Fatalf("sub = %v, want install-abc-123", claims["sub"])
	}
}

// tokenSubject must never let an oversized or control-character-laden header
// value flow straight into a signed claim.
func TestTokenSubjectSanitizesInput(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"empty falls back", "", _powersyncAnonymousSubject},
		{"whitespace-only falls back", "   ", _powersyncAnonymousSubject},
		{"normal id passes through", "install-1", "install-1"},
		{"trims surrounding whitespace", "  install-1  ", "install-1"},
		{"oversized falls back", strings.Repeat("a", _installIDHeaderMaxLen+1), _powersyncAnonymousSubject},
		{"control characters fall back", "install\n1", _powersyncAnonymousSubject},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tokenSubject(tt.input); got != tt.want {
				t.Fatalf("tokenSubject(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestHandleJWKSPublishesSigningKey(t *testing.T) {
	key := testKey(t)
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/jwks", handleJWKS(key))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/jwks", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	var jwks struct {
		Keys []struct {
			Kty string `json:"kty"`
			Alg string `json:"alg"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &jwks); err != nil {
		t.Fatal(err)
	}
	if len(jwks.Keys) != 1 || jwks.Keys[0].Kty != "RSA" || jwks.Keys[0].Alg != "RS256" {
		t.Fatalf("unexpected jwks: %+v", jwks)
	}
	nb, err := base64.RawURLEncoding.DecodeString(jwks.Keys[0].N)
	if err != nil {
		t.Fatal(err)
	}
	eb, err := base64.RawURLEncoding.DecodeString(jwks.Keys[0].E)
	if err != nil {
		t.Fatal(err)
	}
	pub := &rsa.PublicKey{N: new(big.Int).SetBytes(nb), E: int(new(big.Int).SetBytes(eb).Int64())}
	token, err := signRS256(key, map[string]any{"sub": "x"})
	if err != nil {
		t.Fatal(err)
	}
	verifyJWT(t, token, pub)
}

// A silently regenerated key would invalidate every client's PowerSync token
// at once, so the persisted key must survive a restart byte-for-byte.
func TestLoadOrGenerateKeyPersistsAcrossRestarts(t *testing.T) {
	keyFile := t.TempDir() + "/powersync_key.pem"
	first, err := loadOrGenerateKeyAt(keyFile)
	if err != nil {
		t.Fatal(err)
	}
	second, err := loadOrGenerateKeyAt(keyFile)
	if err != nil {
		t.Fatal(err)
	}
	if first.N.Cmp(second.N) != 0 || first.D.Cmp(second.D) != 0 {
		t.Fatal("reloaded key differs from the persisted key")
	}
}

func TestLoadOrGenerateKeyRecoversFromCorruptFile(t *testing.T) {
	keyFile := t.TempDir() + "/powersync_key.pem"
	if err := os.WriteFile(keyFile, []byte("not a pem"), 0600); err != nil {
		t.Fatal(err)
	}
	key, err := loadOrGenerateKeyAt(keyFile)
	if err != nil || key == nil {
		t.Fatalf("key = %v, err = %v", key, err)
	}
	// The regenerated key must be persisted so the next restart reuses it.
	reloaded, err := loadOrGenerateKeyAt(keyFile)
	if err != nil {
		t.Fatal(err)
	}
	if key.N.Cmp(reloaded.N) != 0 {
		t.Fatal("regenerated key was not persisted for the next restart")
	}
}

func TestPrepareHTTPServerSetsRequestTimeouts(t *testing.T) {
	config := httpServerConfig{MetricsCredential: strings.Repeat("m", 32)}
	runtime, err := prepareHTTPServer(nil, nil, config,
		func() (*rsa.PrivateKey, error) { return testKey(t), nil },
		func(string, string) (net.Listener, error) { return &fakeListener{}, nil })
	if err != nil {
		t.Fatal(err)
	}
	if runtime.server.ReadHeaderTimeout <= 0 {
		t.Fatal("ReadHeaderTimeout must be positive")
	}
	if runtime.server.ReadTimeout <= 0 {
		t.Fatal("ReadTimeout must be positive")
	}
	if runtime.server.WriteTimeout <= 0 {
		t.Fatal("WriteTimeout must be positive")
	}
	if runtime.server.IdleTimeout <= 0 {
		t.Fatal("IdleTimeout must be positive")
	}
}

type fakeListener struct{}

func (fakeListener) Accept() (net.Conn, error) { return nil, errors.New("not implemented") }
func (fakeListener) Close() error              { return nil }
func (fakeListener) Addr() net.Addr            { return &net.TCPAddr{} }

func TestLoadOrGenerateKeyPropagatesPersistenceError(t *testing.T) {
	keyFile := t.TempDir() + "/missing-dir/powersync_key.pem"
	_, err := loadOrGenerateKeyAt(keyFile)
	if err == nil {
		t.Fatal("expected an error when the key directory does not exist")
	}
}

func TestLoadOrGenerateKeyPersistsAtomicallyWithOwnerOnlyPermissions(t *testing.T) {
	dir := t.TempDir()
	keyFile := dir + "/powersync_key.pem"
	if _, err := loadOrGenerateKeyAt(keyFile); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(keyFile)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0600 {
		t.Fatalf("key file permissions = %o, want 0600", perm)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("directory has %d entries, want exactly the persisted key file: %v", len(entries), entries)
	}
}

func TestPrepareHTTPServerReturnsKeyAndListenErrorsSynchronously(t *testing.T) {
	config := httpServerConfig{MetricsCredential: strings.Repeat("m", 32)}
	keyErr := errors.New("key unavailable")
	listenCalled := false
	_, err := prepareHTTPServer(nil, nil, config,
		func() (*rsa.PrivateKey, error) { return nil, keyErr },
		func(string, string) (net.Listener, error) {
			listenCalled = true
			return nil, nil
		})
	if !errors.Is(err, keyErr) {
		t.Fatalf("key preparation error = %v, want wrapped %v", err, keyErr)
	}
	if listenCalled {
		t.Fatal("HTTP listener was opened after key preparation failed")
	}

	listenErr := errors.New("address in use")
	_, err = prepareHTTPServer(nil, nil, config,
		func() (*rsa.PrivateKey, error) { return testKey(t), nil },
		func(network, address string) (net.Listener, error) {
			if network != "tcp" || address != "0.0.0.0:8080" {
				t.Fatalf("listen target = %s %s", network, address)
			}
			return nil, listenErr
		})
	if !errors.Is(err, listenErr) {
		t.Fatalf("HTTP listen error = %v, want wrapped %v", err, listenErr)
	}
}

func TestTrackedHTTPHandlerWaitsForActiveHandler(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	handlerDone := make(chan struct{})
	tracked := newTrackedHTTPHandler(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		close(started)
		<-release
		close(handlerDone)
	}))
	go tracked.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/blocked", nil))
	<-started
	waitDone := make(chan struct{})
	go func() {
		tracked.stopAndWait()
		close(waitDone)
	}()
	select {
	case <-waitDone:
		t.Fatal("handler tracker returned while an active handler was blocked")
	default:
	}
	close(release)
	select {
	case <-handlerDone:
	case <-time.After(time.Second):
		t.Fatal("blocked HTTP handler did not finish")
	}
	select {
	case <-waitDone:
	case <-time.After(time.Second):
		t.Fatal("handler tracker did not return after handler completion")
	}
}

func TestHandleMetricsWritesLiveHubCounters(t *testing.T) {
	gin.SetMode(gin.TestMode)
	hub := livestream.NewLiveHub(nopLiveSource{}, 2)
	r := gin.New()
	r.GET("/metrics", handleMetrics(hub))

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	body := w.Body.String()
	for _, metric := range []string{
		"router_live_streams",
		"router_live_channels",
		"router_live_evicted_subscribers_total",
		"router_goroutines",
	} {
		if !strings.Contains(body, metric) {
			t.Fatalf("missing metric %q in %q", metric, body)
		}
	}
}

func TestHTTPRoutesUseIndependentRateBuckets(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := newHTTPRouter(nil, livestream.NewLiveHub(nopLiveSource{}, 2), testKey(t), httpServerConfig{MetricsCredential: strings.Repeat("m", 32)})

	for requestNumber := 1; requestNumber <= _httpTokenRateLimit+1; requestNumber++ {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, "/api/token/powersync", nil)
		router.ServeHTTP(response, request)
		want := http.StatusOK
		if requestNumber > _httpTokenRateLimit {
			want = http.StatusTooManyRequests
		}
		if response.Code != want {
			t.Fatalf("token request %d status = %d, want %d", requestNumber, response.Code, want)
		}
	}

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/.well-known/jwks.json", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("JWKS route consumed token-route quota: status=%d", response.Code)
	}
}

func TestMetricsRequiresConfiguredCredential(t *testing.T) {
	t.Setenv(_metricsCredentialEnv, "")
	if _, err := metricsCredentialFromEnv(); err == nil {
		t.Fatal("empty metrics credential was accepted")
	}
	t.Setenv(_metricsCredentialEnv, "too-short")
	if _, err := metricsCredentialFromEnv(); err == nil {
		t.Fatal("short metrics credential was accepted")
	}

	credential := strings.Repeat("s", 32)
	t.Setenv(_metricsCredentialEnv, credential)
	loaded, err := metricsCredentialFromEnv()
	if err != nil || loaded != credential {
		t.Fatalf("metricsCredentialFromEnv() = (%q, %v)", loaded, err)
	}

	gin.SetMode(gin.TestMode)
	router := newHTTPRouter(nil, livestream.NewLiveHub(nopLiveSource{}, 2), testKey(t), httpServerConfig{MetricsCredential: loaded})
	for _, test := range []struct {
		name          string
		authorization string
		want          int
	}{
		{name: "missing", want: http.StatusUnauthorized},
		{name: "wrong", authorization: "Bearer " + strings.Repeat("x", 32), want: http.StatusUnauthorized},
		{name: "valid", authorization: "Bearer " + credential, want: http.StatusOK},
	} {
		t.Run(test.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodGet, "/metrics?token="+credential, nil)
			if test.authorization != "" {
				request.Header.Set("Authorization", test.authorization)
			}
			router.ServeHTTP(response, request)
			if response.Code != test.want {
				t.Fatalf("status = %d, want %d; body=%q", response.Code, test.want, response.Body.String())
			}
			if test.want != http.StatusOK && strings.Contains(response.Body.String(), "router_goroutines") {
				t.Fatal("unauthorized response disclosed metrics")
			}
		})
	}
}

func TestHTTPServerConfigFromEnvValidatesBeforeStartup(t *testing.T) {
	t.Setenv(_metricsCredentialEnv, strings.Repeat("s", 32))
	t.Setenv(_trustedProxiesEnv, "10.0.0.0/8, 192.0.2.10, 198.51.100.27/24")

	config, err := httpServerConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if config.MetricsCredential != strings.Repeat("s", 32) {
		t.Fatalf("metrics credential = %q", config.MetricsCredential)
	}
	want := []netip.Prefix{
		netip.MustParsePrefix("10.0.0.0/8"),
		netip.MustParsePrefix("192.0.2.10/32"),
		netip.MustParsePrefix("198.51.100.0/24"),
	}
	if len(config.TrustedProxies) != len(want) {
		t.Fatalf("trusted proxies = %v, want %v", config.TrustedProxies, want)
	}
	for i := range want {
		if config.TrustedProxies[i] != want[i] {
			t.Fatalf("trusted proxy %d = %v, want %v", i, config.TrustedProxies[i], want[i])
		}
	}

	t.Setenv(_metricsCredentialEnv, "short")
	if _, err := httpServerConfigFromEnv(); err == nil {
		t.Fatal("short metrics token was accepted")
	}
	t.Setenv(_metricsCredentialEnv, strings.Repeat("s", 32))
	t.Setenv(_trustedProxiesEnv, "not-an-ip")
	if _, err := httpServerConfigFromEnv(); err == nil {
		t.Fatal("invalid trusted proxy was accepted")
	}

	for _, unsafe := range []string{
		"0.0.0.0/0", "::/0", "0.0.0.0", "::",
		"::ffff:0:0/96", "0.1.2.3/8",
	} {
		t.Run("reject unsafe proxy "+unsafe, func(t *testing.T) {
			t.Setenv(_trustedProxiesEnv, unsafe)
			if _, err := httpServerConfigFromEnv(); err == nil {
				t.Fatalf("unsafe trusted proxy %q was accepted", unsafe)
			}
		})
	}
}

func TestDirectHTTPClientCannotRotateRateBucketWithForwardedFor(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := newHTTPRouter(nil, livestream.NewLiveHub(nopLiveSource{}, 2), testKey(t), httpServerConfig{
		MetricsCredential: strings.Repeat("m", 32),
		TokenRateLimit:    1,
	})
	for requestNumber, forwarded := range []string{"198.51.100.1", "198.51.100.2"} {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, "/api/token/powersync", nil)
		request.RemoteAddr = "192.0.2.44:4321"
		request.Header.Set("X-Forwarded-For", forwarded)
		router.ServeHTTP(response, request)
		want := http.StatusOK
		if requestNumber == 1 {
			want = http.StatusTooManyRequests
		}
		if response.Code != want {
			t.Fatalf("request %d rotating X-Forwarded-For status = %d, want %d", requestNumber+1, response.Code, want)
		}
	}
}

func TestHTTPRateLimitUsesSocketPeerUnlessProxyIsTrusted(t *testing.T) {
	gin.SetMode(gin.TestMode)
	credential := strings.Repeat("m", 32)
	testCases := []struct {
		name            string
		trustedProxies  []netip.Prefix
		firstForwarded  string
		secondForwarded string
		wantSecond      int
	}{
		{name: "untrusted proxy header ignored", firstForwarded: "198.51.100.1", secondForwarded: "198.51.100.2", wantSecond: http.StatusTooManyRequests},
		{name: "trusted proxy separates clients", trustedProxies: []netip.Prefix{netip.MustParsePrefix("192.0.2.10/32")}, firstForwarded: "198.51.100.1", secondForwarded: "198.51.100.2", wantSecond: http.StatusOK},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			router := newHTTPRouter(nil, livestream.NewLiveHub(nopLiveSource{}, 2), testKey(t), httpServerConfig{
				MetricsCredential: credential,
				TrustedProxies:    tc.trustedProxies,
				TokenRateLimit:    1,
			})
			request := func(forwarded string) *httptest.ResponseRecorder {
				response := httptest.NewRecorder()
				req := httptest.NewRequest(http.MethodGet, "/api/token/powersync", nil)
				req.RemoteAddr = "192.0.2.10:4321"
				req.Header.Set("X-Forwarded-For", forwarded)
				router.ServeHTTP(response, req)
				return response
			}
			if got := request(tc.firstForwarded).Code; got != http.StatusOK {
				t.Fatalf("first status = %d", got)
			}
			if got := request(tc.secondForwarded).Code; got != tc.wantSecond {
				t.Fatalf("second status = %d, want %d", got, tc.wantSecond)
			}
		})
	}
}

func TestMetricsAuthenticationPrecedesPrincipalRateLimit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	credential := strings.Repeat("m", 32)
	router := newHTTPRouter(nil, livestream.NewLiveHub(nopLiveSource{}, 2), testKey(t), httpServerConfig{
		MetricsCredential: credential,
		MetricsRateLimit:  1,
	})

	for range 3 {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, "/metrics", nil)
		request.Header.Set("Authorization", "Bearer wrong")
		router.ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("unauthorized status = %d", response.Code)
		}
	}

	request := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	request.Header.Set("Authorization", "bEaReR\t"+credential)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("authorized status after failures = %d", response.Code)
	}
	response = httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusTooManyRequests {
		t.Fatalf("second authorized status = %d, want 429", response.Code)
	}
}

func TestMetricsBearerParsingAndSecurityHeaders(t *testing.T) {
	gin.SetMode(gin.TestMode)
	credential := strings.Repeat("m", 32)
	for _, tc := range []struct {
		name   string
		header string
		want   int
	}{
		{name: "case insensitive with spaces", header: "bEaReR   " + credential, want: http.StatusOK},
		{name: "tab separator", header: "Bearer\t" + credential, want: http.StatusOK},
		{name: "empty", header: "Bearer ", want: http.StatusUnauthorized},
		{name: "extra token", header: "Bearer " + credential + " extra", want: http.StatusUnauthorized},
		{name: "leading whitespace", header: " Bearer " + credential, want: http.StatusUnauthorized},
		{name: "trailing whitespace", header: "Bearer " + credential + " ", want: http.StatusUnauthorized},
		{name: "query credential rejected", header: "", want: http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			router := newHTTPRouter(nil, livestream.NewLiveHub(nopLiveSource{}, 2), testKey(t), httpServerConfig{MetricsCredential: credential})
			response := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodGet, "/metrics?token="+credential, nil)
			if tc.header != "" {
				request.Header.Set("Authorization", tc.header)
			}
			router.ServeHTTP(response, request)
			if response.Code != tc.want {
				t.Fatalf("status = %d, want %d", response.Code, tc.want)
			}
			if got := response.Header().Get("Cache-Control"); got != "no-store" {
				t.Fatalf("Cache-Control = %q", got)
			}
			if tc.want == http.StatusUnauthorized && response.Header().Get("WWW-Authenticate") != "Bearer" {
				t.Fatalf("WWW-Authenticate = %q", response.Header().Get("WWW-Authenticate"))
			}
		})
	}
}

func TestSafeAccessLoggerNeverLogsRawQuery(t *testing.T) {
	gin.SetMode(gin.TestMode)
	core, logs := observer.New(zapcore.InfoLevel)
	defer zap.ReplaceGlobals(zap.New(core))()
	router := gin.New()
	router.Use(safeAccessLogger())
	router.GET("/probe", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	secret := "credential-that-must-not-be-logged"
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/probe?token="+secret, nil))
	entries := logs.All()
	if len(entries) != 1 {
		t.Fatalf("access log entries = %d, want 1", len(entries))
	}
	rendered := fmt.Sprint(entries[0].Message, entries[0].ContextMap())
	if strings.Contains(rendered, secret) || strings.Contains(rendered, "token=") {
		t.Fatalf("safe logger exposed query: %q", rendered)
	}
	fields := entries[0].ContextMap()
	for key, want := range map[string]any{"method": "GET", "path": "/probe", "status": int64(204)} {
		if fields[key] != want {
			t.Fatalf("access log %s = %v, want %v", key, fields[key], want)
		}
	}
}

func TestSafeAccessLoggerRecordsHTTPMetricsByRoutePattern(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(safeAccessLogger())
	router.GET("/probe-metrics/:id", func(c *gin.Context) {
		if c.Param("id") == "fail" {
			c.Status(http.StatusInternalServerError)
			return
		}
		c.Status(http.StatusOK)
	})

	router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/probe-metrics/one", nil))
	router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/probe-metrics/two", nil))
	router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/probe-metrics/fail", nil))

	body := obs.MetricsText()
	if !strings.Contains(body, `router_http_requests_total{path="/probe-metrics/:id"} 3`) {
		t.Fatalf("missing aggregated request count in metrics text:\n%s", body)
	}
	if !strings.Contains(body, `router_http_errors_total{path="/probe-metrics/:id"} 1`) {
		t.Fatalf("missing aggregated error count in metrics text:\n%s", body)
	}
}

func TestSafeAccessLoggerLabelsUnmatchedRoutesSeparately(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(safeAccessLogger())

	router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/probe-metrics/does-not-exist-route", nil))

	body := obs.MetricsText()
	if !strings.Contains(body, `router_http_requests_total{path="unmatched"}`) {
		t.Fatalf("expected a 404 to a route not registered by any handler above to be aggregated under \"unmatched\", got:\n%s", body)
	}
}

func TestProductionSentryMiddlewareScrubsMetricsQueryFromEventsAndTransactions(t *testing.T) {
	gin.SetMode(gin.TestMode)
	previousClient := sentry.CurrentHub().Client()
	t.Setenv("SENTRY_DSN", "https://key@example.com/1")
	t.Setenv("SENTRY_TRACES_SAMPLE_RATE", "1")
	flush := obs.Init("router-test")
	defer func() {
		flush()
		sentry.CurrentHub().BindClient(previousClient)
	}()

	options := sentry.CurrentHub().Client().Options()
	transport := &sentry.MockTransport{}
	options.Transport = transport
	client, err := sentry.NewClient(options)
	if err != nil {
		t.Fatal(err)
	}
	sentry.CurrentHub().BindClient(client)

	credential := strings.Repeat("m", 32)
	router := newHTTPRouter(nil, nil, testKey(t), httpServerConfig{MetricsCredential: credential})
	secret := "query-secret-must-never-reach-sentry"
	request := httptest.NewRequest(http.MethodGet, "/metrics?token="+secret, nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("panic probe status = %d, want 500", response.Code)
	}

	var sawError, sawTransaction bool
	for _, event := range transport.Events() {
		serialized, err := json.Marshal(event)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(serialized), secret) {
			t.Fatalf("Sentry payload exposed query credential: %s", serialized)
		}
		if event.Type == "transaction" {
			sawTransaction = true
		} else {
			sawError = true
		}
		if event.Request != nil {
			if event.Request.Method != http.MethodGet || !strings.HasSuffix(event.Request.URL, "/metrics") {
				t.Fatalf("request path/method not preserved: %+v", event.Request)
			}
			if event.Request.QueryString != "" {
				t.Fatalf("Sentry query string = %q", event.Request.QueryString)
			}
		}
	}
	if !sawError || !sawTransaction {
		t.Fatalf("captured event types: error=%v transaction=%v events=%d", sawError, sawTransaction, len(transport.Events()))
	}
}

// nopLiveSource is a LiveSource that never yields data. The HTTP tests only
// need a hub to exist so the metrics handler has something to report.
type nopLiveSource struct{}

func (nopLiveSource) Get(context.Context, string) ([]byte, bool)   { return nil, false }
func (nopLiveSource) ScanKeys(context.Context, string) []string    { return nil }
func (nopLiveSource) Touch(context.Context, string, time.Duration) {}
func (nopLiveSource) Subscribe(context.Context, string) (<-chan []byte, func(), error) {
	ch := make(chan []byte)
	return ch, func() { close(ch) }, nil
}
