package notify

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"firebase.google.com/go/v4/messaging"
)

func TestAPNSNativeHTTPContractAndFailures(t *testing.T) {
	payload := []byte(`{"aps":{"event":"update"}}`)
	statusCode := http.StatusOK
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Method != http.MethodPost || r.URL.Path != "/3/device/test-token" || string(body) != string(payload) {
			t.Errorf("APNs request=%s %s %s", r.Method, r.URL.Path, body)
		}
		for key, want := range map[string]string{"authorization": "bearer test-jwt", "apns-push-type": "liveactivity", "apns-topic": "test-topic", "apns-priority": "10", "content-type": "application/json"} {
			if got := r.Header.Get(key); got != want {
				t.Errorf("%s=%q, want %q", key, got, want)
			}
		}
		w.WriteHeader(statusCode)
		_, _ = io.WriteString(w, "  rejected  \n")
	}))
	defer server.Close()
	sender := &apnsSender{client: server.Client(), host: server.URL, topic: "test-topic", token: "test-jwt", tokenAge: time.Now()}
	if err := sender.SendLiveActivity(context.Background(), "test-token", payload); err != nil {
		t.Fatal(err)
	}
	statusCode = http.StatusGone
	if err := sender.SendLiveActivity(context.Background(), "test-token", payload); !errors.Is(err, ErrAPNSGone) {
		t.Fatalf("gone=%v", err)
	}
	statusCode = http.StatusBadRequest
	if err := sender.SendLiveActivity(context.Background(), "test-token", payload); err == nil || !strings.Contains(err.Error(), "apns") {
		t.Fatalf("rejected=%v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := sender.SendLiveActivity(ctx, "test-token", payload); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled=%v", err)
	}
	sender.host = ":invalid"
	if err := sender.SendLiveActivity(context.Background(), "test-token", payload); err == nil {
		t.Fatal("malformed URL accepted")
	}
}

func TestFirebaseConstructorUsesCredentialsAndCanceledSend(t *testing.T) {
	t.Setenv("FIREBASE_ENABLED", "true")
	t.Setenv("APP_ENV", "test")
	t.Setenv("FIREBASE_PROJECT_ID", "")
	if _, err := NewFirebaseSender(context.Background()); err == nil {
		t.Fatal("missing project accepted")
	}
	t.Setenv("FIREBASE_PROJECT_ID", "quality-project")
	path := filepath.Join(t.TempDir(), "credentials.json")
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", path)
	if _, err := NewFirebaseSender(context.Background()); err == nil {
		t.Fatal("missing credentials accepted")
	}
	if err := os.WriteFile(path, []byte(`{"invalid":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewFirebaseSender(context.Background()); err == nil {
		t.Fatal("malformed credentials accepted")
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	encoded := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: mustPKCS8(t, key)})
	raw, err := json.Marshal(map[string]string{"type": "service_account", "project_id": "quality-project", "private_key_id": "quality-key", "private_key": string(encoded), "client_email": "quality@quality-project.iam.gserviceaccount.com", "client_id": "123", "token_uri": "https://oauth2.googleapis.com/token"})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	sender, err := NewFirebaseSender(context.Background())
	if err != nil || sender == nil {
		t.Fatalf("sender=%v err=%v", sender, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := sender.Send(ctx, &messaging.Message{Token: "quality-token", Data: map[string]string{"test": "value"}}); err == nil {
		t.Fatal("canceled send succeeded")
	}
}

func mustPKCS8(t *testing.T, key *rsa.PrivateKey) []byte {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return der
}
