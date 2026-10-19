package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/riderfwd"
	"github.com/redis/go-redis/v9"
)

func TestTokenSubjectAcceptsExactLimitAndRejectsLeadingControl(t *testing.T) {
	for _, tt := range []struct{ name, input, want string }{
		{"exact length limit", strings.Repeat("a", _installIDHeaderMaxLen), strings.Repeat("a", _installIDHeaderMaxLen)},
		{"leading control", "\x00installation", _powersyncAnonymousSubject},
		{"embedded space", "installation 1", "installation 1"},
		{"delete control", "installation\x7f1", _powersyncAnonymousSubject},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := tokenSubject(tt.input); got != tt.want {
				t.Fatalf("subject = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHTTPQuotaRetryAfterUsesWholeSeconds(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, principal := range []bool{false, true} {
		t.Run(map[bool]string{false: "address", true: "principal"}[principal], func(t *testing.T) {
			router := gin.New()
			limiter := ratelimit.New()
			middleware := httpRateLimit(limiter, "quota", 1, 5*time.Second)
			if principal {
				router.Use(func(c *gin.Context) { c.Set(_metricsPrincipalContextKey, "monitor") })
				middleware = httpPrincipalRateLimit(limiter, "quota", 1, 5*time.Second)
			}
			router.GET("/quota", middleware, func(c *gin.Context) { c.Status(http.StatusNoContent) })
			for _, status := range []int{http.StatusNoContent, http.StatusTooManyRequests} {
				recorder := httptest.NewRecorder()
				router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/quota", nil))
				if recorder.Code != status {
					t.Fatalf("status = %d, want %d", recorder.Code, status)
				}
				if status == http.StatusTooManyRequests && recorder.Header().Get("Retry-After") != "5" {
					t.Fatalf("Retry-After = %q, want five seconds", recorder.Header().Get("Retry-After"))
				}
			}
		})
	}
}

func TestAtomicSigningKeyRenameFailureLeavesNoTemporaryFile(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "key.pem")
	if err := os.Mkdir(destination, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := persistKeyAtomically(destination, []byte("key bytes")); err == nil || !strings.Contains(err.Error(), "rename") {
		t.Fatalf("publishing over a directory = %v", err)
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "key.pem" || !entries[0].IsDir() {
		t.Fatalf("failed key publication left files: %v", entries)
	}
}

type shutdownDeadline struct {
	deadline time.Time
	present  bool
}

type deadlineHTTPServer struct{ deadline chan shutdownDeadline }

func (*deadlineHTTPServer) Serve(net.Listener) error { return nil }
func (*deadlineHTTPServer) Close() error             { return nil }
func (s *deadlineHTTPServer) Shutdown(ctx context.Context) error {
	deadline, present := ctx.Deadline()
	s.deadline <- shutdownDeadline{deadline: deadline, present: present}
	return nil
}

type immediateGRPCServer struct{}

func (immediateGRPCServer) Serve(net.Listener) error { return nil }
func (immediateGRPCServer) GracefulStop()            {}
func (immediateGRPCServer) Stop()                    {}

func TestServerCoordinatorDefaultsNonPositiveShutdownDeadline(t *testing.T) {
	for _, tt := range []struct {
		name             string
		configured, want time.Duration
	}{
		{"zero", 0, 5 * time.Second},
		{"negative", -time.Second, 5 * time.Second},
		{"positive", 73 * time.Millisecond, 73 * time.Millisecond},
	} {
		t.Run(tt.name, func(t *testing.T) {
			httpServer := &deadlineHTTPServer{deadline: make(chan shutdownDeadline, 1)}
			coordinator := serverCoordinator{httpServer: httpServer, grpcServer: immediateGRPCServer{}, shutdownTimeout: tt.configured}
			before := time.Now()
			stopped := make(chan struct{})
			go func() { coordinator.stopServers(); close(stopped) }()
			awaitAPIEvent(t, stopped, "server shutdown")
			after := time.Now()
			observed := awaitAPIEvent(t, httpServer.deadline, "HTTP deadline")
			if !observed.present || observed.deadline.Before(before.Add(tt.want)) || observed.deadline.After(after.Add(tt.want)) {
				t.Fatalf("shutdown deadline = %v (present %t), want %v after shutdown started", observed.deadline, observed.present, tt.want)
			}
		})
	}
}

func TestHTTPDrainWaitsForEveryAdmittedRequest(t *testing.T) {
	started := make(chan string, 1)
	firstRelease, lastRelease := make(chan struct{}), make(chan struct{})
	firstDone, lastDone := make(chan struct{}), make(chan struct{})
	var firstOnce, lastOnce sync.Once
	releaseFirst := func() { firstOnce.Do(func() { close(firstRelease) }) }
	releaseLast := func() { lastOnce.Do(func() { close(lastRelease) }) }
	tracked := newTrackedHTTPHandler(http.HandlerFunc(func(_ http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/first":
			started <- "first"
			<-firstRelease
		case "/last":
			started <- "last"
			<-lastRelease
		}
	}))
	go func() {
		tracked.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/first", nil))
		close(firstDone)
	}()
	go func() {
		tracked.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/last", nil))
		close(lastDone)
	}()
	t.Cleanup(func() {
		releaseFirst()
		releaseLast()
		awaitAPIEvent(t, firstDone, "first request cleanup")
		awaitAPIEvent(t, lastDone, "last request cleanup")
	})
	awaitAPIEvent(t, started, "first admitted request")
	awaitAPIEvent(t, started, "second admitted request")
	stopDone := make(chan struct{})
	go func() { tracked.stopAndWait(); close(stopDone) }()
	deadline := time.Now().Add(2 * time.Second)
	for {
		recorder := httptest.NewRecorder()
		tracked.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/probe", nil))
		if recorder.Code == http.StatusServiceUnavailable {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("HTTP shutdown did not stop admission")
		}
		runtime.Gosched()
	}
	releaseFirst()
	awaitAPIEvent(t, firstDone, "first request completion")
	select {
	case <-tracked.done:
		t.Fatal("HTTP drain completed while a second admitted request was blocked")
	default:
	}
	releaseLast()
	awaitAPIEvent(t, lastDone, "final request completion")
	awaitAPIEvent(t, stopDone, "HTTP drain completion")
}

func awaitAPIEvent[T any](t *testing.T, events <-chan T, name string) T {
	t.Helper()
	select {
	case value := <-events:
		return value
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", name)
	}
	var zero T
	return zero
}

func TestOptionalHTTPRoutesFollowConfiguredBackends(t *testing.T) {
	gin.SetMode(gin.TestMode)
	key := testKey(t)
	for _, enabled := range []bool{false, true} {
		t.Run(map[bool]string{false: "disabled", true: "enabled"}[enabled], func(t *testing.T) {
			config := httpServerConfig{MetricsCredential: strings.Repeat("m", 32)}
			if enabled {
				config.trackCancel = func(c *gin.Context) { c.Status(http.StatusNoContent) }
				config.redis = redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
				t.Cleanup(func() { _ = config.redis.Close() })
			}
			router := gin.New()
			registerHTTPRoutes(router, nil, nil, key, config)
			for _, route := range []struct {
				method, path string
				status       int
			}{
				{http.MethodPost, riderfwd.TrackCancelPath, http.StatusNoContent},
				{http.MethodGet, "/gbfs/gbfs.json", http.StatusOK},
			} {
				want := http.StatusNotFound
				if enabled {
					want = route.status
				}
				recorder := httptest.NewRecorder()
				router.ServeHTTP(recorder, httptest.NewRequest(route.method, route.path, nil))
				if recorder.Code != want {
					t.Fatalf("%s %s = %d, want %d", route.method, route.path, recorder.Code, want)
				}
			}
		})
	}
}
