package static

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
)

func assetsRouter(t *testing.T, dir string) (*gin.Engine, *int) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	limited := 0
	RegisterAssetRoutes(r, dir, func(c *gin.Context) {
		limited++
		c.Next()
	})
	return r, &limited
}

func getAsset(r *gin.Engine, path string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	return w
}

func TestAssetsServesFilesThroughTheLimiter(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "mrt"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "mrt", "R.svg"), []byte("<svg/>"), 0o600); err != nil {
		t.Fatal(err)
	}
	r, limited := assetsRouter(t, dir)

	w := getAsset(r, AssetsPath+"/mrt/R.svg")

	if w.Code != http.StatusOK || w.Body.String() != "<svg/>" {
		t.Fatalf("got %d %q, want 200 <svg/>", w.Code, w.Body.String())
	}
	if *limited != 1 {
		t.Fatalf("limiter ran %d times, want 1", *limited)
	}
}

func TestAssetsDoesNotListDirectories(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	r, _ := assetsRouter(t, dir)

	if w := getAsset(r, AssetsPath+"/"); w.Code == http.StatusOK {
		t.Fatalf("directory listing answered 200: %q", w.Body.String())
	}
}

func TestAssetsUnmountedWithoutDir(t *testing.T) {
	r, limited := assetsRouter(t, "")

	if w := getAsset(r, AssetsPath+"/manifest.json"); w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", w.Code)
	}
	if *limited != 0 {
		t.Fatalf("limiter ran %d times on an unmounted route", *limited)
	}
}
