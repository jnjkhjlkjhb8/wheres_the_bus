// Package firebase owns device registration, notification preferences, and
// arrival reminders, plus App Check verification for the whole router. It is
// the device store every other device-scoped service authenticates against.
package firebase

import (
	"context"
	"crypto/tls"
	"errors"
	"os"
	"strings"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/appcheck"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	AppCheckMetadataKey = "x-firebase-appcheck"
)

// Clients have sent mixed case here (Dart's TargetPlatform.iOS.name is
// "iOS"); the firebase_device CHECK constraint only accepts lowercase.

// maxRouteSubscriptions bounds one device's 訂閱範圍. It is far above any
// plausible 收藏 list and exists only so a malformed or hostile client
// cannot make the server build an unbounded array.

// validAlertRoute reports whether a transit type can carry disruption alerts.
// It mirrors the route_type CHECK on firebase_route_subscription, so a bad
// value is rejected here rather than surfacing as a constraint violation.

// Rail arrival times are known at creation, so fire on a schedule (arrival
// minus lead). Bus has no known arrival time and fires off the live ETA, so
// it leaves fire_at NULL and is dispatched from busEta instead.

// CancelArrivalReminder cancels a caller's pending reminder. It returns NotFound
// when no matching pending reminder exists (already fired, already cancelled, or
// owned by a different install). The caller is authorized first.

// ListDeviceState returns the stored preferences for a device. It returns
// NotFound when the install has no row. As with UpsertDevice, the fcm_token is
// stripped from the response.

type AppCheckVerifier interface {
	VerifyToken(context.Context, string) error
}

type firebaseAppCheckVerifier struct{ client *appcheck.Client }

// VerifyToken checks a Firebase App Check token via the Admin SDK. The context
// is unused because the underlying appcheck client verifies offline against
// cached public keys.
func (v firebaseAppCheckVerifier) VerifyToken(_ context.Context, token string) error {
	_, err := v.client.VerifyToken(token)
	return err
}

func FirebaseAppCheckFromEnv(ctx context.Context) (AppCheckVerifier, bool, error) {
	enabled := firebaseEnabledFromEnv()
	if !enabled {
		return nil, false, nil
	}
	var config *firebase.Config
	if projectID := os.Getenv("FIREBASE_PROJECT_ID"); projectID != "" {
		config = &firebase.Config{ProjectID: projectID}
	}
	app, err := firebase.NewApp(ctx, config)
	if err != nil {
		return nil, false, _oops.Wrapf(err, "initialize Firebase Admin")
	}
	client, err := app.AppCheck(ctx)
	if err != nil {
		return nil, false, _oops.Wrapf(err, "initialize Firebase App Check")
	}
	return firebaseAppCheckVerifier{client: client}, true, nil
}

func firebaseEnabledFromEnv() bool {
	return strings.EqualFold(os.Getenv("FIREBASE_ENABLED"), "true") && !strings.EqualFold(os.Getenv("APP_ENV"), "dev")
}

func grpcTLSEnabledFromEnv() bool {
	return strings.EqualFold(os.Getenv("GRPC_TLS"), "true")
}

// GRPCTLSCredentialsFromEnv builds server TLS credentials when GRPC_TLS is
// enabled. It fails closed: GRPC_TLS=true without both cert and key paths
// is a startup error rather than a silent fall-back to plaintext.
func GRPCTLSCredentialsFromEnv() (credentials.TransportCredentials, error) {
	if !grpcTLSEnabledFromEnv() {
		return nil, nil
	}
	certFile, keyFile := os.Getenv("GRPC_TLS_CERT_FILE"), os.Getenv("GRPC_TLS_KEY_FILE")
	if certFile == "" || keyFile == "" {
		return nil, errors.New("GRPC_TLS_CERT_FILE and GRPC_TLS_KEY_FILE are required when GRPC_TLS is enabled")
	}
	certificate, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, _oops.Wrapf(err, "load gRPC TLS certificate")
	}
	return credentials.NewTLS(&tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS12,
	}), nil
}

func AppCheckUnaryInterceptor(verifier AppCheckVerifier, enabled bool) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, request any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if !enabled || !strings.HasPrefix(info.FullMethod, "/Firebase_Service/") {
			return handler(ctx, request)
		}
		if err := verifyAppCheck(ctx, verifier, info.FullMethod); err != nil {
			return nil, err
		}
		return handler(ctx, request)
	}
}

func AppCheckStreamInterceptor(verifier AppCheckVerifier, enabled bool) grpc.StreamServerInterceptor {
	return func(server any, stream grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if !enabled || !strings.HasPrefix(info.FullMethod, "/Firebase_Service/") {
			return handler(server, stream)
		}
		if err := verifyAppCheck(stream.Context(), verifier, info.FullMethod); err != nil {
			return err
		}
		return handler(server, stream)
	}
}

func verifyAppCheck(ctx context.Context, verifier AppCheckVerifier, method string) error {
	values := metadata.ValueFromIncomingContext(ctx, AppCheckMetadataKey)
	if len(values) != 1 || values[0] == "" || verifier == nil {
		zap.S().Warnw("app check rejected",
			"component", "firebase",
			"action", "app_check",
			"event", "token_absent",
			"method", method,
			"tokens", len(values),
		)
		return status.Error(codes.Unauthenticated, "valid Firebase App Check token required")
	}
	if err := verifier.VerifyToken(ctx, values[0]); err != nil {
		zap.S().Warnw("app check rejected",
			"component", "firebase",
			"action", "app_check",
			"event", "token_invalid",
			"method", method,
			"err", err,
		)
		return status.Error(codes.Unauthenticated, "valid Firebase App Check token required")
	}
	return nil
}

// NewFirebaseServer wires the device store, the clock, and the live source the
// reminder demand gate touches.
