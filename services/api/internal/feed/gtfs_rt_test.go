package feed

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

const _gtfsRTTestCredential = "0123456789abcdef0123456789abcdef"

func gtfsRTTestEngine(t *testing.T, rc *redis.Client, credential string) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	RegisterGTFSRTRoutes(engine, rc, credential, func(c *gin.Context) { c.Next() })
	return engine
}

// gtfsRTUnreachableRedis is a client pointed at a closed port, so every command
// fails fast. It stands in for "the snapshot is not there", which is the only
// state the handler has to distinguish.
func gtfsRTUnreachableRedis(t *testing.T) *redis.Client {
	t.Helper()
	return redis.NewClient(&redis.Options{
		Addr:        "127.0.0.1:1",
		DialTimeout: 50 * time.Millisecond,
		ReadTimeout: 50 * time.Millisecond,
		MaxRetries:  0,
	})
}

func gtfsRTRequest(t *testing.T, engine *gin.Engine, authorization string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, GTFSRTPath, nil)
	if authorization != "" {
		request.Header.Set("Authorization", authorization)
	}
	recorder := httptest.NewRecorder()
	engine.ServeHTTP(recorder, request)
	return recorder
}

func TestGTFSRTRouteIsNotMountedWithoutACredential(t *testing.T) {
	// Prod binds the HTTP port to 0.0.0.0 with no proxy in front, so an
	// environment that was never given a secret must serve no feed rather than
	// an open one.
	engine := gtfsRTTestEngine(t, gtfsRTUnreachableRedis(t), "")
	if got := gtfsRTRequest(t, engine, "").Code; got != http.StatusNotFound {
		t.Errorf("status = %d, want 404 (route should not exist)", got)
	}
}

func TestGTFSRTRouteIsNotMountedWithoutRedis(t *testing.T) {
	engine := gtfsRTTestEngine(t, nil, _gtfsRTTestCredential)
	if got := gtfsRTRequest(t, engine, "Bearer "+_gtfsRTTestCredential).Code; got != http.StatusNotFound {
		t.Errorf("status = %d, want 404 (route should not exist)", got)
	}
}

func TestGTFSRTRejectsAMissingOrWrongCredential(t *testing.T) {
	engine := gtfsRTTestEngine(t, gtfsRTUnreachableRedis(t), _gtfsRTTestCredential)
	for name, authorization := range map[string]string{
		"absent":     "",
		"wrong":      "Bearer fedcba9876543210fedcba9876543210",
		"not bearer": "Basic " + _gtfsRTTestCredential,
		"bare token": _gtfsRTTestCredential,
	} {
		recorder := gtfsRTRequest(t, engine, authorization)
		if recorder.Code != http.StatusUnauthorized {
			t.Errorf("%s credential: status = %d, want 401", name, recorder.Code)
		}
		if recorder.Header().Get("WWW-Authenticate") != "Bearer" {
			t.Errorf("%s credential: missing WWW-Authenticate challenge", name)
		}
	}
}

func TestGTFSRTServes503WhenTheSnapshotIsAbsent(t *testing.T) {
	// An empty FeedMessage would be a valid claim that nothing is cancelled,
	// which is the wrong thing to say when the truth is that the builder is not
	// running. The endpoint must fail instead, so MOTIS keeps the static plan.
	engine := gtfsRTTestEngine(t, gtfsRTUnreachableRedis(t), _gtfsRTTestCredential)
	recorder := gtfsRTRequest(t, engine, "Bearer "+_gtfsRTTestCredential)
	if recorder.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", recorder.Code)
	}
	if recorder.Body.Len() != 0 {
		t.Errorf("body = %q, want empty", recorder.Body.String())
	}
}

func TestGTFSRTCredentialFromEnvRejectsWeakValues(t *testing.T) {
	for name, value := range map[string]string{
		"too short": "short",
		"padded":    " " + _gtfsRTTestCredential + " ",
	} {
		t.Setenv(_gtfsRTCredentialEnv, value)
		if _, err := GTFSRTCredentialFromEnv(); err == nil {
			t.Errorf("%s credential was accepted", name)
		}
	}
	// Empty is a decision, not a misconfiguration: it means "do not mount".
	t.Setenv(_gtfsRTCredentialEnv, "")
	credential, err := GTFSRTCredentialFromEnv()
	if err != nil || credential != "" {
		t.Errorf("empty credential = %q, %v; want \"\", nil", credential, err)
	}
	t.Setenv(_gtfsRTCredentialEnv, _gtfsRTTestCredential)
	credential, err = GTFSRTCredentialFromEnv()
	if err != nil || credential != _gtfsRTTestCredential {
		t.Errorf("valid credential = %q, %v", credential, err)
	}
}
