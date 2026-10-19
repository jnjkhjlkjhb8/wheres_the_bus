package main

import (
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func localRouterEnvironment(t *testing.T) {
	t.Helper()
	if os.Getenv("DATABASE_URL") == "" || os.Getenv("REDIS_ADDR") == "" {
		t.Skip("DATABASE_URL or REDIS_ADDR not set")
	}
	for key, value := range map[string]string{"FIREBASE_ENABLED": "false", "MAAS_BACKEND": "tdx", "RIDER_API_ADDR": "127.0.0.1:1", "RIDER_HTTP_URL": "http://127.0.0.1:1", "RIDER_TLS_DIR": "", "GRPC_TLS": "false", "ROUTER_METRICS_TOKEN": strings.Repeat("q", 32), "ROUTER_TRUSTED_PROXIES": "", "GTFS_RT_CREDENTIAL": "", "SENTRY_DSN": ""} {
		t.Setenv(key, value)
	}
	keyPath := filepath.Join(t.TempDir(), "powersync.pem")
	if _, err := loadOrGenerateKeyAt(keyPath); err != nil {
		t.Fatal(err)
	}
	t.Setenv("POWERSYNC_KEY_FILE", keyPath)
}

func TestRouterStartupServesAndShutsDownBothListeners(t *testing.T) {
	localRouterEnvironment(t)
	listeners := make(chan net.Listener, 2)
	listen := func(network, _ string) (net.Listener, error) {
		listener, err := net.Listen(network, "127.0.0.1:0")
		if err == nil {
			listeners <- listener
		}
		return listener, err
	}
	shutdown := make(chan os.Signal, 1)
	done := make(chan error, 1)
	runtime := &routerRuntime{}
	go func() { done <- runtime.run(func() error { return runtime.start(shutdown, listen) }) }()
	t.Cleanup(func() {
		select {
		case shutdown <- syscall.SIGTERM:
		default:
		}
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("router did not finish cleanup")
		}
	})
	var grpcListener, httpListener net.Listener
	for _, target := range []*net.Listener{&grpcListener, &httpListener} {
		select {
		case *target = <-listeners:
		case err := <-done:
			done <- err
			t.Fatalf("startup failed: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("listener was not bound")
		}
	}
	client := &http.Client{Timeout: time.Second}
	resp, err := client.Get("http://" + httpListener.Addr().String() + "/api/.well-known/jwks.json")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("JWKS status = %d", resp.StatusCode)
	}
	shutdown <- syscall.SIGTERM
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("shutdown error = %v", err)
		}
		done <- nil
	case <-time.After(10 * time.Second):
		t.Fatal("graceful shutdown timed out")
	}
	for _, listener := range []net.Listener{grpcListener, httpListener} {
		if conn, err := net.DialTimeout("tcp", listener.Addr().String(), 100*time.Millisecond); err == nil {
			_ = conn.Close()
			t.Fatal("listener remained open after cleanup")
		}
	}
}

func TestRouterStartupFailuresReleaseBoundResources(t *testing.T) {
	localRouterEnvironment(t)
	for _, tc := range []struct{ name, key, value, want string }{
		{"configuration", "ROUTER_METRICS_TOKEN", "short", "HTTP configuration"},
		{"rider address", "RIDER_API_ADDR", "bad-address", "parse RIDER_API_ADDR"},
		{"signing key", "POWERSYNC_KEY_FILE", "/missing/router-key.pem", ""},
		{"grpc TLS", "GRPC_TLS", "true", "gRPC TLS initialization"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(tc.key, tc.value)
			t.Setenv("GRPC_TLS_CERT_FILE", "")
			t.Setenv("GRPC_TLS_KEY_FILE", "")
			var listeners []net.Listener
			listen := func(network, _ string) (net.Listener, error) {
				listener, err := net.Listen(network, "127.0.0.1:0")
				if err == nil {
					listeners = append(listeners, listener)
				}
				return listener, err
			}
			runtime := &routerRuntime{}
			err := runtime.run(func() error { return runtime.start(make(chan os.Signal), listen) })
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("startup error = %v, want %q", err, tc.want)
			}
			for _, listener := range listeners {
				if conn, err := net.DialTimeout("tcp", listener.Addr().String(), 100*time.Millisecond); err == nil {
					_ = conn.Close()
					t.Fatal("failed startup leaked listener")
				}
			}
		})
	}
	listenErr := errors.New("listener unavailable")
	runtime := &routerRuntime{}
	if err := runtime.run(func() error {
		return runtime.start(make(chan os.Signal), func(string, string) (net.Listener, error) { return nil, listenErr })
	}); !errors.Is(err, listenErr) {
		t.Fatalf("listener error = %v", err)
	}
}

func TestPoolStatisticsLoopRespondsToTickAndStop(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" {
		t.Skip("DATABASE_URL not set")
	}
	pool, err := pgxpool.New(t.Context(), os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	ticks := make(chan time.Time)
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() { defer close(done); logPoolStatsOnTick(pool, stop, ticks) }()
	ticks <- time.Now()
	close(stop)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("pool statistics did not stop")
	}
	logPoolStats(pool, stop)
}
