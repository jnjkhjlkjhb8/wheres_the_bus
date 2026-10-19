package firebase

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

type failingAppCheckTransport struct{ err error }

func (t failingAppCheckTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, t.err
}

func TestFirebaseAppCheckInitializationFailsClosed(t *testing.T) {
	t.Setenv("APP_ENV", "prod")
	t.Setenv("FIREBASE_ENABLED", "false")
	verifier, enabled, err := FirebaseAppCheckFromEnv(t.Context())
	if err != nil || enabled || verifier != nil {
		t.Fatalf("disabled Firebase = %v, %v, %v", verifier, enabled, err)
	}
	t.Setenv("FIREBASE_ENABLED", "true")
	t.Setenv("FIREBASE_PROJECT_ID", "")
	t.Setenv("FIREBASE_CONFIG", "{invalid")
	if verifier, enabled, err := FirebaseAppCheckFromEnv(t.Context()); err == nil || enabled || verifier != nil {
		t.Fatalf("malformed Firebase configuration = %v, %v, %v", verifier, enabled, err)
	}
	// Keep Admin SDK key discovery local and deterministic without Google credentials.
	original := http.DefaultClient
	upstreamErr := errors.New("key discovery unavailable")
	http.DefaultClient = &http.Client{Transport: failingAppCheckTransport{err: upstreamErr}}
	t.Cleanup(func() { http.DefaultClient = original })
	t.Setenv("FIREBASE_PROJECT_ID", "quality-local-project")
	if verifier, enabled, err := FirebaseAppCheckFromEnv(context.Background()); err == nil || enabled || verifier != nil {
		t.Fatalf("failed key discovery = %v, %v, %v", verifier, enabled, err)
	}
}
