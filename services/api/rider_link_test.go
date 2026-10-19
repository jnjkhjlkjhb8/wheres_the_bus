package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestRiderLinkValidatesAddressURLAndTLS(t *testing.T) {
	t.Setenv("RIDER_TLS_DIR", "")
	t.Setenv("RIDER_API_ADDR", "not-an-address")
	t.Setenv("RIDER_HTTP_URL", "http://127.0.0.1:1")
	if _, err := dialRider(); err == nil {
		t.Fatal("invalid gRPC address accepted")
	}
	t.Setenv("RIDER_API_ADDR", "127.0.0.1:1")
	t.Setenv("RIDER_HTTP_URL", "://bad-url")
	if _, err := dialRider(); err == nil {
		t.Fatal("invalid HTTP URL accepted")
	}
	t.Setenv("RIDER_HTTP_URL", "http://127.0.0.1:1")
	t.Setenv("RIDER_TLS_DIR", t.TempDir())
	if _, err := dialRider(); err == nil {
		t.Fatal("missing mTLS credentials accepted")
	}
}

func TestRiderLinkForwardsCancellationOverConfiguredTLS(t *testing.T) {
	upstream := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || len(r.TLS.PeerCertificates) != 1 || r.Method != http.MethodPost || r.URL.Query().Get("track_id") != "test-track" {
			t.Error("cancellation did not preserve request or present client certificate")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	upstream.TLS = &tls.Config{ClientAuth: tls.RequireAnyClientCert, MinVersion: tls.VersionTLS13}
	upstream.StartTLS()
	defer upstream.Close()
	certificate := upstream.TLS.Certificates[0]
	key, err := x509.MarshalPKCS8PrivateKey(certificate.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for name, data := range map[string][]byte{"tls.crt": pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Certificate[0]}), "ca.crt": pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Certificate[0]}), "tls.key": pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("RIDER_API_ADDR", "127.0.0.1:1")
	t.Setenv("RIDER_HTTP_URL", upstream.URL)
	t.Setenv("RIDER_TLS_DIR", dir)
	link, err := dialRider()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = link.conn.Close() }()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.POST("/cancel", link.trackCancel)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/cancel?track_id=test-track", nil).WithContext(t.Context()))
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("cancellation status = %d body=%s", recorder.Code, recorder.Body)
	}
}
