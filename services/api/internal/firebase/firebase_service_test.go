package firebase

import (
	"context"
	cryptorand "crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// Every route_type the alert path can dispatch must be storable, including
// the "*" line-wide marker a rail-station 收藏 resolves to.

// Clearing every 收藏 must clear the stored scope, not leave the last set
// standing — that is the ghost-subscription bug this replaces.

// Rail reminders fire on a schedule: the server derives fire_at = arrival
// (expires_at) − lead so the reminder cron can dispatch it without a live ETA.

// The credential gate must reject requests that carry no installation metadata
// at all, or a secret below the 32-byte minimum — both would otherwise let an
// anonymous caller mutate another install's subscriptions and reminders.

// Cancelling a reminder that is not pending for this install (already fired,
// cancelled, or owned by someone else) must surface NotFound, not silent success.

// Older app builds send Dart's TargetPlatform.iOS.name ("iOS"), which the
// firebase_device CHECK constraint rejects; the server lowercases it.

type fakeAppCheckVerifier struct{ err error }

func (f fakeAppCheckVerifier) VerifyToken(_ context.Context, token string) error {
	if token != "valid" {
		return errors.New("invalid token")
	}
	return f.err
}

func TestAppCheckUnaryInterceptor(t *testing.T) {
	handler := func(context.Context, any) (any, error) { return "ok", nil }
	info := &grpc.UnaryServerInfo{FullMethod: pb.Firebase_Service_UpsertDevice_FullMethodName}

	t.Run("disabled bypass", func(t *testing.T) {
		got, err := AppCheckUnaryInterceptor(nil, false)(context.Background(), nil, info, handler)
		if err != nil || got != "ok" {
			t.Fatalf("result = %v, error = %v", got, err)
		}
	})

	for _, tc := range []struct {
		name  string
		token string
		want  codes.Code
	}{
		{"missing", "", codes.Unauthenticated},
		{"invalid", "invalid", codes.Unauthenticated},
		{"valid", "valid", codes.OK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			if tc.token != "" {
				ctx = metadata.NewIncomingContext(ctx, metadata.Pairs(AppCheckMetadataKey, tc.token))
			}
			_, err := AppCheckUnaryInterceptor(fakeAppCheckVerifier{}, true)(ctx, nil, info, handler)
			if code := status.Code(err); code != tc.want {
				t.Fatalf("code = %v, want %v", code, tc.want)
			}
		})
	}
}

func TestFirebaseEnabledFromEnv(t *testing.T) {
	for _, tc := range []struct {
		name, enabled, environment string
		want                       bool
	}{
		{"production enabled", "true", "prod", true},
		{"development bypass", "true", "dev", false},
		{"feature disabled", "false", "prod", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("FIREBASE_ENABLED", tc.enabled)
			t.Setenv("APP_ENV", tc.environment)
			if got := firebaseEnabledFromEnv(); got != tc.want {
				t.Fatalf("firebaseEnabledFromEnv() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestGRPCTLSCredentialsFromEnv(t *testing.T) {
	t.Run("disabled bypass regardless of Firebase", func(t *testing.T) {
		t.Setenv("GRPC_TLS", "false")
		t.Setenv("FIREBASE_ENABLED", "true")
		t.Setenv("APP_ENV", "prod")
		t.Setenv("GRPC_TLS_CERT_FILE", "")
		t.Setenv("GRPC_TLS_KEY_FILE", "")
		credentials, err := GRPCTLSCredentialsFromEnv()
		if err != nil || credentials != nil {
			t.Fatalf("credentials = %v, error = %v", credentials, err)
		}
	})

	t.Run("enabled without Firebase still requires certificate and key", func(t *testing.T) {
		t.Setenv("GRPC_TLS", "true")
		t.Setenv("FIREBASE_ENABLED", "false")
		t.Setenv("APP_ENV", "staging")
		t.Setenv("GRPC_TLS_CERT_FILE", "")
		t.Setenv("GRPC_TLS_KEY_FILE", "")
		if _, err := GRPCTLSCredentialsFromEnv(); err == nil {
			t.Fatal("grpcTLSCredentialsFromEnv() error = nil, want fail-closed error")
		}
	})

	t.Run("enabled loads a valid certificate and key", func(t *testing.T) {
		certFile, keyFile := writeSelfSignedCertPair(t)
		t.Setenv("GRPC_TLS", "true")
		t.Setenv("FIREBASE_ENABLED", "false")
		t.Setenv("APP_ENV", "staging")
		t.Setenv("GRPC_TLS_CERT_FILE", certFile)
		t.Setenv("GRPC_TLS_KEY_FILE", keyFile)
		credentials, err := GRPCTLSCredentialsFromEnv()
		if err != nil {
			t.Fatalf("grpcTLSCredentialsFromEnv() error = %v", err)
		}
		if credentials == nil {
			t.Fatal("grpcTLSCredentialsFromEnv() credentials = nil, want non-nil")
		}
	})

	t.Run("invalid certificate path fails closed", func(t *testing.T) {
		t.Setenv("GRPC_TLS", "true")
		t.Setenv("FIREBASE_ENABLED", "false")
		t.Setenv("APP_ENV", "staging")
		t.Setenv("GRPC_TLS_CERT_FILE", "/nonexistent/grpc.crt")
		t.Setenv("GRPC_TLS_KEY_FILE", "/nonexistent/grpc.key")
		if _, err := GRPCTLSCredentialsFromEnv(); err == nil {
			t.Fatal("grpcTLSCredentialsFromEnv() error = nil, want load failure")
		}
	})
}

// writeSelfSignedCertPair generates a throwaway self-signed certificate and
// key pair for exercising tls.LoadX509KeyPair, and returns their file paths.
func writeSelfSignedCertPair(t *testing.T) (certFile, keyFile string) {
	t.Helper()
	key, err := rsa.GenerateKey(cryptorand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "router-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
	}
	derBytes, err := x509.CreateCertificate(cryptorand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	dir := t.TempDir()
	certFile = dir + "/grpc.crt"
	keyFile = dir + "/grpc.key"
	certOut, err := os.Create(certFile)
	if err != nil {
		t.Fatalf("create cert file: %v", err)
	}
	defer func() { _ = certOut.Close() }()
	if err := pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes}); err != nil {
		t.Fatalf("encode certificate: %v", err)
	}
	keyOut, err := os.Create(keyFile)
	if err != nil {
		t.Fatalf("create key file: %v", err)
	}
	defer func() { _ = keyOut.Close() }()
	if err := pem.Encode(keyOut, &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}); err != nil {
		t.Fatalf("encode key: %v", err)
	}
	return certFile, keyFile
}

type testServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s testServerStream) Context() context.Context { return s.ctx }

func TestAppCheckStreamInterceptor(t *testing.T) {
	info := &grpc.StreamServerInfo{FullMethod: "/Firebase_Service/futureStream"}
	handler := func(any, grpc.ServerStream) error { return nil }

	missing := testServerStream{ctx: context.Background()}
	if code := status.Code(AppCheckStreamInterceptor(fakeAppCheckVerifier{}, true)(nil, missing, info, handler)); code != codes.Unauthenticated {
		t.Fatalf("missing token code = %v, want %v", code, codes.Unauthenticated)
	}
	if err := AppCheckStreamInterceptor(nil, false)(nil, missing, info, handler); err != nil {
		t.Fatalf("disabled interceptor error = %v", err)
	}
}

// demandLiveSource is a livestream.LiveSource that records only the demand touches; the
// reminder path never reads or subscribes.

// TestCreateArrivalReminderSkipsRailDemand keeps rail out of the gate: rail
// reminders carry a fire_at and dispatch on a schedule, so they do not depend
// on any city staying at full polling cadence.
