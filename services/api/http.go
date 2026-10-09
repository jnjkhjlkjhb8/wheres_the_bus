package main

import (
	"crypto"
	cryptorand "crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	sentrygin "github.com/getsentry/sentry-go/gin"
	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/feed"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/maas"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/rail"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/riderfwd"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/search"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/static"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	// The only port the HTTP server ever serves on. The GBFS discovery document
	// has to advertise the same one, so it is handed to RegisterGBFSRoutes
	// rather than duplicated there.
	_httpPort             = "8080"
	_metricsCredentialEnv = "ROUTER_METRICS_TOKEN"
	_trustedProxiesEnv    = "ROUTER_TRUSTED_PROXIES"
	_httpTokenRateLimit   = 10
	_httpJWKSRateLimit    = 120
	_httpSearchRateLimit  = 30
	_httpMetricsRateLimit = 60
	_httpBookingRateLimit = 30
	_httpGBFSRateLimit    = 120
	// MOTIS polls its realtime endpoints once a minute by default, and the feed
	// has exactly one authenticated consumer, so this is generous already.
	_httpGTFSRTRateLimit        = 10
	_httpGeocodeRateLimit       = 60
	_httpPlannerStatusRateLimit = 60
	// One fetch per app launch, answered from a process-local cache, so this
	// only has to survive a device relaunching in a loop.
	_httpStaticVersionRateLimit = 60

	_httpReadHeaderTimeout = 5 * time.Second
	_httpReadTimeout       = 10 * time.Second
	_httpWriteTimeout      = 15 * time.Second
	_httpIdleTimeout       = 60 * time.Second

	_powersyncTokenTTL         = time.Hour
	_powersyncAnonymousSubject = "powersync-client"
	_installIDHeaderMaxLen     = 128
)

type httpServerConfig struct {
	MetricsCredential string
	TrustedProxies    []netip.Prefix
	TokenRateLimit    int
	JWKSRateLimit     int
	SearchRateLimit   int
	// Where MOTIS is reached, and whether it is the configured planner. Both
	// come from main so the geocode proxy cannot disagree with the planner
	// about which backend is live.
	MotisBaseURL string
	MotisEnabled bool
	// The same monitor maas.MaasServer consults, so /api/planner reports the backend
	// that is actually answering rather than a second opinion about it.
	plannerHealth    *maas.PlannerHealthMonitor
	MetricsRateLimit int
	booking          *rail.BookingProxy
	redis            *redis.Client
	// GBFSRateLimit bounds GBFS polling per client. The feed is public and
	// unauthenticated, and station_status costs a full station scan.
	GBFSRateLimit          int
	GTFSRealtimeCredential string
	// trackCancel proxies the Live Activity cancel to rider-api; nil leaves
	// the route unmounted.
	trackCancel gin.HandlerFunc
}

func httpServerConfigFromEnv() (httpServerConfig, error) {
	metricsCredential, err := metricsCredentialFromEnv()
	if err != nil {
		return httpServerConfig{}, err
	}
	trustedProxies, err := trustedProxiesFromEnv()
	if err != nil {
		return httpServerConfig{}, err
	}
	gtfsRTCredential, err := feed.GTFSRTCredentialFromEnv()
	if err != nil {
		return httpServerConfig{}, err
	}
	return httpServerConfig{
		MetricsCredential:      metricsCredential,
		TrustedProxies:         trustedProxies,
		GTFSRealtimeCredential: gtfsRTCredential,
		MotisBaseURL:           maas.MotisBaseURLFromEnv(),
		// Read from the same env var the planner reads, so the geocode proxy
		// and the planner can never disagree about which backend is live.
		MotisEnabled: !maas.MaasBackendFromEnv(),
	}, nil
}

func trustedProxiesFromEnv() ([]netip.Prefix, error) {
	raw := strings.TrimSpace(os.Getenv(_trustedProxiesEnv))
	if raw == "" {
		return nil, nil
	}
	parts := strings.Split(raw, ",")
	proxies := make([]netip.Prefix, 0, len(parts))
	for _, part := range parts {
		value := strings.TrimSpace(part)
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			addr, addrErr := netip.ParseAddr(value)
			if addrErr != nil {
				return nil, _oops.With("_trusted_proxies_env", _trustedProxiesEnv).With("value", value).Errorf("contains invalid IP or CIDR")
			}
			prefix = netip.PrefixFrom(addr, addr.BitLen())
		}
		prefix = prefix.Masked()
		addressBits := prefix.Addr().BitLen()
		network := &net.IPNet{
			IP:   net.IP(prefix.Addr().AsSlice()),
			Mask: net.CIDRMask(prefix.Bits(), addressBits),
		}
		if network.Contains(net.IPv4zero) || network.Contains(net.IPv6zero) {
			return nil, _oops.With("_trusted_proxies_env", _trustedProxiesEnv).With("value", value).Errorf("contains unsafe catch-all or unspecified proxy")
		}
		proxies = append(proxies, prefix)
	}
	return proxies, nil
}

type trackedHTTPHandler struct {
	handler  http.Handler
	mu       sync.Mutex
	active   int
	stopping bool
	done     chan struct{}
	doneOnce sync.Once
}

func newTrackedHTTPHandler(handler http.Handler) *trackedHTTPHandler {
	return &trackedHTTPHandler{handler: handler, done: make(chan struct{})}
}

func (h *trackedHTTPHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	h.mu.Lock()
	if h.stopping {
		h.mu.Unlock()
		http.Error(writer, "server shutting down", http.StatusServiceUnavailable)
		return
	}
	h.active++
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		h.active--
		if h.stopping && h.active == 0 {
			h.doneOnce.Do(func() { close(h.done) })
		}
		h.mu.Unlock()
	}()
	h.handler.ServeHTTP(writer, request)
}

func (h *trackedHTTPHandler) stopAndWait() {
	h.mu.Lock()
	h.stopping = true
	if h.active == 0 {
		h.doneOnce.Do(func() { close(h.done) })
	}
	done := h.done
	h.mu.Unlock()
	<-done
}

type preparedHTTPServer struct {
	server   *http.Server
	listener net.Listener
	handlers *trackedHTTPHandler
}

func prepareHTTPServer(
	db *pgxpool.Pool,
	live *livestream.LiveHub,
	config httpServerConfig,
	loadKey func() (*rsa.PrivateKey, error),
	listen func(string, string) (net.Listener, error),
) (preparedHTTPServer, error) {
	key, err := loadKey()
	if err != nil {
		return preparedHTTPServer{}, _oops.Wrapf(err, "prepare HTTP signing key")
	}
	zap.S().Infow("RS256 key ready", "component", "http")
	gin.SetMode(gin.ReleaseMode)
	handlers := newTrackedHTTPHandler(newHTTPRouter(db, live, key, config))
	server := &http.Server{
		Handler:           handlers,
		ReadHeaderTimeout: _httpReadHeaderTimeout,
		ReadTimeout:       _httpReadTimeout,
		WriteTimeout:      _httpWriteTimeout,
		IdleTimeout:       _httpIdleTimeout,
	}
	listener, err := listen("tcp", net.JoinHostPort("0.0.0.0", _httpPort))
	if err != nil {
		return preparedHTTPServer{}, _oops.Wrapf(err, "listen for HTTP")
	}
	return preparedHTTPServer{server: server, listener: listener, handlers: handlers}, nil
}

func newHTTPRouter(db *pgxpool.Pool, live *livestream.LiveHub, key *rsa.PrivateKey, config httpServerConfig) *gin.Engine {
	r := gin.New()
	trustedProxies := make([]string, len(config.TrustedProxies))
	for index, prefix := range config.TrustedProxies {
		trustedProxies[index] = prefix.String()
	}
	if err := r.SetTrustedProxies(trustedProxies); err != nil {
		panic(fmt.Sprintf("validated trusted proxy configuration rejected: %v", err))
	}
	r.Use(safeAccessLogger(), gin.Recovery())
	r.Use(sentrygin.New(sentrygin.Options{Repanic: true}))
	limiter := ratelimit.New()
	tokenLimit := configuredLimit(config.TokenRateLimit, _httpTokenRateLimit)
	jwksLimit := configuredLimit(config.JWKSRateLimit, _httpJWKSRateLimit)
	searchLimit := configuredLimit(config.SearchRateLimit, _httpSearchRateLimit)
	metricsLimit := configuredLimit(config.MetricsRateLimit, _httpMetricsRateLimit)
	gbfsLimit := configuredLimit(config.GBFSRateLimit, _httpGBFSRateLimit)
	r.GET("/api/token/powersync",
		httpRateLimit(limiter, "GET /api/token/powersync", tokenLimit, time.Minute),
		handleToken(key))
	r.GET("/api/.well-known/jwks.json",
		httpRateLimit(limiter, "GET /api/.well-known/jwks.json", jwksLimit, time.Minute),
		handleJWKS(key))
	r.GET("/api/search",
		httpRateLimit(limiter, "GET /api/search", searchLimit, time.Second),
		search.HandleSearch(db))
	r.GET(static.StaticVersionPath,
		httpRateLimit(limiter, "GET "+static.StaticVersionPath, _httpStaticVersionRateLimit, time.Minute),
		static.HandleStaticVersion(db))
	search.RegisterGeocodeRoutes(r, config.MotisBaseURL, config.MotisEnabled,
		httpRateLimit(limiter, "GET "+search.GeocodePath, _httpGeocodeRateLimit, time.Minute))
	// Always mounted, unlike the geocode proxy: an app that cannot tell which
	// planner is live has to guess which options it may offer, and guessing is
	// what this exists to remove.
	maas.RegisterPlannerStatusRoutes(r, config.plannerHealth,
		httpRateLimit(limiter, "GET "+maas.PlannerStatusPath, _httpPlannerStatusRateLimit, time.Minute))
	r.GET("/api/booking/deeplink",
		httpRateLimit(limiter, "GET /api/booking/deeplink", _httpBookingRateLimit, time.Minute),
		rail.HandleBookingDeeplink(config.booking))
	// rider-api owns tracking sessions; api only rate-limits and passes through.
	if config.trackCancel != nil {
		r.POST(riderfwd.TrackCancelPath,
			httpRateLimit(limiter, "POST "+riderfwd.TrackCancelPath, riderfwd.HTTPTrackCancelRateLimit, time.Minute),
			config.trackCancel)
	}
	// GBFS is mounted only with a Redis client: station_status is the point of
	// the feed, and it cannot be answered without one.
	if config.redis != nil {
		feed.RegisterGBFSRoutes(r, db, config.redis,
			httpRateLimit(limiter, "GET /gbfs", gbfsLimit, time.Minute), _httpPort)
	}
	feed.RegisterGTFSRTRoutes(r, config.redis, config.GTFSRealtimeCredential,
		httpRateLimit(limiter, "GET "+feed.GTFSRTPath, _httpGTFSRTRateLimit, time.Minute))
	r.GET("/metrics",
		requireMetricsCredential(config.MetricsCredential),
		httpPrincipalRateLimit(limiter, "GET /metrics", metricsLimit, time.Minute),
		handleMetrics(live))
	return r
}

func configuredLimit(configured, fallback int) int {
	if configured > 0 {
		return configured
	}
	return fallback
}

func safeAccessLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		started := time.Now()
		c.Next()
		status := c.Writer.Status()
		routePath := c.FullPath()
		if routePath == "" {
			routePath = "unmatched"
		}
		obs.RecordHTTPRequest(routePath, status)
		// EscapedPath, never RequestURI: the raw query can carry a bearer token
		// or another credential a client appended, and an access log is the one
		// place it would be persisted verbatim.
		zap.S().Infow("http request",
			"method", c.Request.Method,
			"path", c.Request.URL.EscapedPath(),
			"status", status,
			"latency", time.Since(started),
		)
	}
}

func httpRateLimit(limiter *ratelimit.Limiter, scope string, limit int, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		caller := c.ClientIP()
		if caller == "" {
			caller = "unknown"
		}
		if !limiter.Allow(scope, caller, limit, window) {
			c.Header("Retry-After", fmt.Sprint(max(1, int(window/time.Second))))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "rate limit exceeded"})
			return
		}
		c.Next()
	}
}

const _metricsPrincipalContextKey = "metrics-principal"

func httpPrincipalRateLimit(limiter *ratelimit.Limiter, scope string, limit int, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		principal, ok := c.Get(_metricsPrincipalContextKey)
		caller, valid := principal.(string)
		if !ok || !valid || caller == "" {
			c.AbortWithStatus(http.StatusUnauthorized)
			return
		}
		if !limiter.Allow(scope, caller, limit, window) {
			c.Header("Retry-After", fmt.Sprint(max(1, int(window/time.Second))))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "rate limit exceeded"})
			return
		}
		c.Next()
	}
}

func metricsCredentialFromEnv() (string, error) {
	credential := os.Getenv(_metricsCredentialEnv)
	if credential != strings.TrimSpace(credential) {
		return "", _oops.With("_metrics_credential_env", _metricsCredentialEnv).Errorf("must not contain leading or trailing whitespace")
	}
	if len(credential) < 32 {
		return "", _oops.With("_metrics_credential_env", _metricsCredentialEnv).Errorf("must be configured with at least 32 characters")
	}
	return credential, nil
}

// requireMetricsCredential accepts the credential only in the Authorization
// header, keeping it out of URLs and access logs. Hashing both values before the
// constant-time comparison avoids leaking the configured credential length.
func requireMetricsCredential(expected string) gin.HandlerFunc {
	expectedHash := sha256.Sum256([]byte(expected))
	principal := fmt.Sprintf("metrics:%x", expectedHash[:8])
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		provided := installid.ParseBearerCredential(c.GetHeader("Authorization"))
		providedHash := sha256.Sum256([]byte(provided))
		if provided == "" || subtle.ConstantTimeCompare(providedHash[:], expectedHash[:]) != 1 {
			c.Header("WWW-Authenticate", "Bearer")
			c.AbortWithStatus(http.StatusUnauthorized)
			return
		}
		c.Set(_metricsPrincipalContextKey, principal)
		c.Next()
	}
}
func handleMetrics(live *livestream.LiveHub) gin.HandlerFunc {
	return func(c *gin.Context) {
		stats := live.Stats()
		body := fmt.Sprintf(
			"router_live_streams %d\nrouter_live_channels %d\nrouter_live_evicted_subscribers_total %d\nrouter_goroutines %d\n%s",
			stats.ActiveStreams,
			stats.ActiveChannels,
			stats.EvictedSubscribers,
			runtime.NumGoroutine(),
			obs.MetricsText(),
		)
		c.Data(200, "text/plain; version=0.0.4; charset=utf-8", []byte(body))
	}
}

func handleToken(key *rsa.PrivateKey) gin.HandlerFunc {
	return func(c *gin.Context) {
		now := time.Now()
		token, err := signRS256(key, map[string]any{
			"sub": tokenSubject(c.GetHeader(installid.MetadataKey)),
			"aud": "powersync",
			"iat": now.Unix(),
			"exp": now.Add(_powersyncTokenTTL).Unix(),
		})
		if err != nil {
			c.JSON(500, gin.H{"error": "sign failed"})
			return
		}
		c.JSON(200, gin.H{"token": token})
	}
}

func tokenSubject(installID string) string {
	installID = strings.TrimSpace(installID)
	if installID == "" || len(installID) > _installIDHeaderMaxLen {
		return _powersyncAnonymousSubject
	}
	for _, r := range installID {
		if r < 0x20 || r == 0x7f {
			return _powersyncAnonymousSubject
		}
	}
	return installID
}
func handleJWKS(key *rsa.PrivateKey) gin.HandlerFunc {
	pub := &key.PublicKey
	n := base64.RawURLEncoding.EncodeToString(pub.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes())
	body := gin.H{
		"keys": []gin.H{{
			"kty": "RSA", "use": "sig", "alg": "RS256", "kid": "k1",
			"n": n, "e": e,
		}},
	}
	return func(c *gin.Context) { c.JSON(200, body) }
}
func signRS256(key *rsa.PrivateKey, claims map[string]any) (string, error) {
	header := b64j(map[string]string{"alg": "RS256", "typ": "JWT", "kid": "k1"})
	payload := b64j(claims)
	msg := header + "." + payload
	h := sha256.New()
	h.Write([]byte(msg))
	sig, err := rsa.SignPKCS1v15(cryptorand.Reader, key, crypto.SHA256, h.Sum(nil))
	if err != nil {
		return "", err
	}
	return msg + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}
func b64j(v any) string {
	b, _ := json.Marshal(v)
	return base64.RawURLEncoding.EncodeToString(b)
}

// loadSigningKey loads the PowerSync JWT signing key every api replica shares.
// With POWERSYNC_KEY_FILE set (always, in k3s) the key must already exist: two
// replicas generating their own would sign tokens the other's JWKS rejects, so
// a missing or unreadable key stops startup instead. Unset, it falls back to
// generate-on-first-boot for a single local process.
func loadSigningKey() (*rsa.PrivateKey, error) {
	path := os.Getenv("POWERSYNC_KEY_FILE")
	if path == "" {
		return loadOrGenerateKey()
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, _oops.With("key_file", path).Wrapf(err, "read PowerSync signing key")
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, _oops.With("key_file", path).Errorf("PowerSync signing key is not PEM")
	}
	key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return nil, _oops.With("key_file", path).Wrapf(err, "parse PowerSync signing key")
	}
	return key, nil
}

func loadOrGenerateKey() (*rsa.PrivateKey, error) {
	return loadOrGenerateKeyAt("/data/powersync_key.pem")
}

func loadOrGenerateKeyAt(keyFile string) (*rsa.PrivateKey, error) {
	data, err := os.ReadFile(keyFile)
	if err == nil {
		block, _ := pem.Decode(data)
		if block != nil {
			key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
			if err == nil {
				zap.S().Infow("loaded persisted RSA key", "component", "http", "key_file", keyFile)
				return key, nil
			}
		}
	}
	key, err := rsa.GenerateKey(cryptorand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	data = pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})
	if err := persistKeyAtomically(keyFile, data); err != nil {
		return nil, _oops.Wrapf(err, "persist RSA key")
	}
	zap.S().Infow("generated new RSA key", "component", "http", "key_file", keyFile)
	return key, nil
}

func persistKeyAtomically(keyFile string, data []byte) error {
	dir := filepath.Dir(keyFile)
	tmp, err := os.CreateTemp(dir, filepath.Base(keyFile)+".tmp-*")
	if err != nil {
		return _oops.Wrapf(err, "create temp key file")
	}
	tmpName := tmp.Name()
	renamed := false
	defer func() {
		if !renamed {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return _oops.Wrapf(err, "write temp key file")
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return _oops.Wrapf(err, "sync temp key file")
	}
	if err := tmp.Close(); err != nil {
		return _oops.Wrapf(err, "close temp key file")
	}
	if err := os.Chmod(tmpName, 0600); err != nil {
		return _oops.Wrapf(err, "chmod temp key file")
	}
	if err := os.Rename(tmpName, keyFile); err != nil {
		return _oops.Wrapf(err, "rename temp key file into place")
	}
	renamed = true
	return nil
}
