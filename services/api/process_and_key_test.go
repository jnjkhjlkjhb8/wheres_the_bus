package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

func TestRunProcessReportsFailureAndExitsOnlyOnFailure(t *testing.T) {
	for _, fail := range []bool{false, true} {
		var stderr bytes.Buffer
		var exitCodes []int
		runProcess(&stderr, func() error {
			if fail {
				return errors.New("startup unavailable")
			}
			return nil
		}, func(code int) { exitCodes = append(exitCodes, code) })
		if fail {
			if len(exitCodes) != 1 || exitCodes[0] != 1 || !strings.Contains(stderr.String(), "startup unavailable") {
				t.Fatalf("failure exits = %v, report %q", exitCodes, stderr.String())
			}
		} else if len(exitCodes) != 0 || stderr.Len() != 0 {
			t.Fatalf("successful process exits = %v, report %q", exitCodes, stderr.String())
		}
	}
}

func TestUnexpectedServerStopsPreserveCause(t *testing.T) {
	for _, result := range []serverResult{{name: "gRPC"}, {name: "HTTP", err: http.ErrServerClosed}, {name: "gRPC", err: http.ErrServerClosed}} {
		err := unexpectedServeError(result)
		if err == nil {
			t.Fatalf("server result %v = %v", result, err)
		}
		if result.name == "gRPC" && result.err != nil && !errors.Is(err, result.err) {
			t.Fatalf("unexpected stop lost cause: %v", err)
		}
	}
}

func TestHTTPConfigurationRejectsMalformedRealtimeCredential(t *testing.T) {
	t.Setenv(_metricsCredentialEnv, strings.Repeat("q", 32))
	t.Setenv(_trustedProxiesEnv, "")
	t.Setenv("GTFS_RT_CREDENTIAL", " leading-whitespace")
	if _, err := httpServerConfigFromEnv(); err == nil {
		t.Fatal("malformed realtime credential accepted")
	}
}

func TestInstallationLimiterPassesRequestsWithoutInstallation(t *testing.T) {
	interceptor := installationRateLimitInterceptor(ratelimit.New(), 1, time.Minute)
	info := &grpc.UnaryServerInfo{FullMethod: pb.Firebase_Service_UpsertDevice_FullMethodName}
	for range 2 {
		got, err := interceptor(t.Context(), nil, info, func(context.Context, any) (any, error) { return "handled", nil })
		if got != "handled" || err != nil {
			t.Fatalf("unidentified installation = %v, error %v", got, err)
		}
	}
	info.FullMethod = pb.MaasService_Plan_FullMethodName
	if got, err := interceptor(t.Context(), nil, info, func(context.Context, any) (any, error) { return "other service", nil }); got != "other service" || err != nil {
		t.Fatalf("non-Firebase service = %v, error %v", got, err)
	}
}

func TestGRPCConfigurationServesTLSWithTheConfiguredCertificate(t *testing.T) {
	localRouterEnvironment(t)
	t.Setenv("GRPC_TLS", "true")
	fixture := httptest.NewTLSServer(http.NotFoundHandler())
	t.Cleanup(fixture.Close)
	certificate := fixture.TLS.Certificates[0]
	key, err := x509.MarshalPKCS8PrivateKey(certificate.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	certFile, keyFile := filepath.Join(t.TempDir(), "cert.pem"), filepath.Join(t.TempDir(), "key.pem")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Certificate[0]}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GRPC_TLS_CERT_FILE", certFile)
	t.Setenv("GRPC_TLS_KEY_FILE", keyFile)
	opts, err := grpcOptionsFromEnv(httpServerConfig{}, ratelimit.New())
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer(opts...)
	healthpb.RegisterHealthServer(server, health.NewServer())
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	roots := x509.NewCertPool()
	roots.AddCert(fixture.Certificate())
	client, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12})))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	if _, err := healthpb.NewHealthClient(client).Check(ctx, &healthpb.HealthCheckRequest{}); err != nil {
		t.Fatalf("configured TLS health check = %v", err)
	}
}

func TestGRPCConfigurationFailsClosedForInvalidFirebaseConfiguration(t *testing.T) {
	t.Setenv("FIREBASE_ENABLED", "true")
	t.Setenv("APP_ENV", "test")
	t.Setenv("FIREBASE_PROJECT_ID", "")
	t.Setenv("FIREBASE_CONFIG", "{")
	t.Setenv("GRPC_TLS", "false")
	if _, err := grpcOptionsFromEnv(httpServerConfig{}, ratelimit.New()); err == nil {
		t.Fatal("invalid Firebase configuration allowed startup")
	}
}

func TestRouterStartsConfiguredMotisAndCleansUpOnSignal(t *testing.T) {
	localRouterEnvironment(t)
	health := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"initialized":true,"hasTimetable":true}`))
	}))
	defer health.Close()
	t.Setenv("MOTIS_BASE_URL", health.URL)
	shutdown := make(chan os.Signal, 1)
	shutdown <- syscall.SIGTERM
	runtime := &routerRuntime{}
	err := runtime.run(func() error {
		return runtime.start(shutdown, func(network, _ string) (net.Listener, error) {
			return net.Listen(network, "127.0.0.1:0")
		})
	})
	if err != nil {
		t.Fatal(err)
	}
}

type failingKeyWriter struct {
	stage     string
	err       error
	closed    int
	written   []byte
	syncCalls int
}

func (f *failingKeyWriter) Write(data []byte) (int, error) {
	if f.stage == "write" {
		return 0, f.err
	}
	f.written = append(f.written, data...)
	return len(data), nil
}

func (f *failingKeyWriter) Sync() error {
	f.syncCalls++
	if f.stage == "sync" {
		return f.err
	}
	return nil
}

func (f *failingKeyWriter) Close() error {
	f.closed++
	if f.stage == "close" {
		return f.err
	}
	return nil
}

func TestKeyWriterClosesAndPropagatesEveryPersistenceStageFailure(t *testing.T) {
	for _, stage := range []string{"write", "sync", "close", "success"} {
		t.Run(stage, func(t *testing.T) {
			want := errors.New("key " + stage + " unavailable")
			writer := &failingKeyWriter{stage: stage, err: want}
			err := writeKeyFile(writer, []byte("key bytes"))
			if stage == "success" {
				if err != nil {
					t.Fatal(err)
				}
			} else if !errors.Is(err, want) {
				t.Fatalf("key stage error = %v, want %v", err, want)
			}
			if writer.closed != 1 {
				t.Fatalf("key file closed %d times, want exactly once", writer.closed)
			}
			if stage != "write" && (string(writer.written) != "key bytes" || writer.syncCalls != 1) {
				t.Fatalf("written = %q, sync calls = %d", writer.written, writer.syncCalls)
			}
		})
	}
}

func TestPrepareKeyFilePreservesWritePermissionAndRenameErrors(t *testing.T) {
	for _, stage := range []string{"write", "chmod", "rename"} {
		t.Run(stage, func(t *testing.T) {
			tmp, err := os.CreateTemp(t.TempDir(), "key")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = tmp.Close() })
			destination := filepath.Join(t.TempDir(), "published.pem")
			switch stage {
			case "write":
				if err := tmp.Close(); err != nil {
					t.Fatal(err)
				}
			case "chmod":
				if err := os.Remove(tmp.Name()); err != nil {
					t.Fatal(err)
				}
			case "rename":
				destination = t.TempDir()
			}
			if err := prepareKeyFile(tmp, destination, []byte("key")); err == nil || !strings.Contains(err.Error(), stage) {
				t.Fatalf("%s failure = %v", stage, err)
			}
		})
	}
}

func TestServingPreparationPropagatesGRPCBindFailure(t *testing.T) {
	want := errors.New("listener unavailable")
	runtime := &routerRuntime{}
	_, err := runtime.prepareServing(httpServerConfig{}, nil, nil, "", func(string, string) (net.Listener, error) {
		return nil, want
	})
	if !errors.Is(err, want) || len(runtime.cleanups) != 0 {
		t.Fatalf("bind failure = %v, registered cleanups %d", err, len(runtime.cleanups))
	}
}
