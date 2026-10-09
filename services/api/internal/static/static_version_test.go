package static

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
)

func staticVersionRouter(read func(context.Context) (string, error)) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET(StaticVersionPath, handleStaticVersion(cache.NewTTLCache(), read))
	return r
}

func getStaticVersion(t *testing.T, r *gin.Engine) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, StaticVersionPath, nil))
	return w
}

func TestStaticVersionServesAndCachesTheMarker(t *testing.T) {
	reads := 0
	r := staticVersionRouter(func(context.Context) (string, error) {
		reads++
		return "1754179200", nil
	})

	for range 2 {
		w := getStaticVersion(t, r)
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", w.Code)
		}
		var got staticVersionResponse
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if got.Version != "1754179200" {
			t.Fatalf("version = %q, want 1754179200", got.Version)
		}
	}
	// The second request must not have reached the database: the value only
	// moves once a night, and every app launch asks for it.
	if reads != 1 {
		t.Fatalf("reads = %d, want 1 (second request should hit the cache)", reads)
	}
}

func TestStaticVersionFailsLoudlyAndCachesNothing(t *testing.T) {
	gin.SetMode(gin.TestMode)
	cache := cache.NewTTLCache()
	fail := true
	r := gin.New()
	r.GET(StaticVersionPath, handleStaticVersion(cache, func(context.Context) (string, error) {
		if fail {
			return "", errors.New("database down")
		}
		return "1754179200", nil
	}))

	if w := getStaticVersion(t, r); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", w.Code)
	}
	// A failure must never be cached: the client keeps its existing cache on a
	// 503, so a cached error would extend a blip into five minutes of it.
	if _, ok := cache.Get(_staticVersionCacheKey); ok {
		t.Fatal("error response was cached")
	}
	fail = false
	if w := getStaticVersion(t, r); w.Code != http.StatusOK {
		t.Fatalf("status after recovery = %d, want 200", w.Code)
	}
}
