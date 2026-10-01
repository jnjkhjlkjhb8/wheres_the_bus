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
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/appcheck"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/installid"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
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

type firebasePersistence interface {
	UpsertDevice(context.Context, *pb.DeviceIdentity, *pb.DevicePrefs, []byte) (*pb.DeviceState, bool, error)
	AuthorizeInstall(context.Context, string, []byte) (bool, error)
	ReplaceRouteSubscriptions(context.Context, string, []*pb.RouteSubscription) error
	CreateArrivalReminder(context.Context, FirebaseArrivalReminder) error
	CancelArrivalReminder(context.Context, string, string) (bool, error)
	ListDeviceState(context.Context, string) (*pb.DeviceState, error)
}

type FirebaseServer struct {
	pb.UnimplementedFirebase_ServiceServer
	store firebasePersistence
	now   func() time.Time
	live  livestream.LiveSource
}

func (s *FirebaseServer) UpsertDevice(ctx context.Context, request *pb.UpsertDeviceRequest) (*pb.DeviceState, error) {
	identity, prefs := request.GetIdentity(), request.GetPrefs()
	if identity == nil || prefs == nil || !installid.ValidText(identity.GetInstallId(), 128) || !installid.ValidText(identity.GetPlatform(), 16) {
		return nil, status.Error(codes.InvalidArgument, "identity and preferences are required")
	}
	// Clients have sent mixed case here (Dart's TargetPlatform.iOS.name is
	// "iOS"); the firebase_device CHECK constraint only accepts lowercase.
	identity.Platform = strings.ToLower(identity.Platform)
	if identity.Platform != "android" && identity.Platform != "ios" {
		return nil, status.Error(codes.InvalidArgument, "platform must be android or ios")
	}
	if prefs.PushEnabled && !installid.ValidText(identity.FcmToken, 4096) {
		return nil, status.Error(codes.InvalidArgument, "fcm_token is required when push is enabled")
	}
	secretHash, err := installid.SecretHash(ctx, identity.InstallId)
	if err != nil {
		return nil, err
	}
	state, authorized, err := s.store.UpsertDevice(ctx, identity, prefs, secretHash)
	if err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "upsert_device",
			"event", "store_failed",
			"install", identity.InstallId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to save device")
	}
	if !authorized {
		return nil, status.Error(codes.PermissionDenied, "installation credential does not match")
	}
	state.Identity.FcmToken = ""
	return state, nil
}

func (s *FirebaseServer) ReplaceRouteSubscriptions(ctx context.Context, request *pb.RouteSubscriptionsRequest) (*pb.Ack, error) {
	// maxRouteSubscriptions bounds one device's 訂閱範圍. It is far above any
	// plausible 收藏 list and exists only so a malformed or hostile client
	// cannot make the server build an unbounded array.
	const maxRouteSubscriptions = 1000
	if !installid.ValidText(request.GetInstallId(), 128) {
		return nil, status.Error(codes.InvalidArgument, "install_id is required")
	}
	subscriptions := request.GetSubscriptions()
	if len(subscriptions) > maxRouteSubscriptions {
		return nil, status.Errorf(codes.InvalidArgument, "at most %d subscriptions", maxRouteSubscriptions)
	}
	for _, subscription := range subscriptions {
		if !validAlertRoute(subscription.GetRouteType()) || !installid.ValidText(subscription.GetRouteKey(), 256) {
			return nil, status.Error(codes.InvalidArgument, "each subscription needs a known route_type and a route_key")
		}
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	if err := s.store.ReplaceRouteSubscriptions(ctx, request.InstallId, subscriptions); err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "replace_route_subscriptions",
			"event", "store_failed",
			"install", request.InstallId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to save route subscriptions")
	}
	return &pb.Ack{Ok: true}, nil
}

// validAlertRoute reports whether a transit type can carry disruption alerts.
// It mirrors the route_type CHECK on firebase_route_subscription, so a bad
// value is rejected here rather than surfacing as a constraint violation.
func validAlertRoute(routeType string) bool {
	switch routeType {
	case "bus", "mrt", "tra", "thsr":
		return true
	}
	return false
}

func (s *FirebaseServer) CreateArrivalReminder(ctx context.Context, request *pb.CreateArrivalReminderRequest) (*pb.ArrivalReminder, error) {
	if !installid.ValidText(request.GetInstallId(), 128) || !validRoute(request.GetRouteType()) ||
		!installid.ValidText(request.GetRouteKey(), 256) || !installid.ValidText(request.GetStopKey(), 256) || !installid.ValidText(request.GetDirection(), 32) {
		return nil, status.Error(codes.InvalidArgument, "install_id, route, stop, and direction are required")
	}
	switch request.RouteType {
	case "bus", "tra", "thsr":
	default:
		return nil, status.Error(codes.FailedPrecondition, "arrival reminders are supported for bus and rail routes only")
	}
	if request.Direction != "0" && request.Direction != "1" {
		return nil, status.Error(codes.InvalidArgument, "direction must be 0 or 1")
	}
	if request.LeadMinutes < 1 || request.LeadMinutes > 120 {
		return nil, status.Error(codes.InvalidArgument, "lead_minutes must be between 1 and 120")
	}
	plate := strings.ToUpper(strings.TrimSpace(request.GetPlate()))
	if !validNormalizedPlate(plate) {
		return nil, status.Error(codes.InvalidArgument, "plate must contain only letters, digits, and single hyphen separators")
	}
	alightEvent := request.GetAlightEvent()
	if !validAlightEvent(alightEvent) {
		return nil, status.Error(codes.InvalidArgument, "alight_event must be lead, alight, or empty")
	}
	now := s.now
	if now == nil {
		now = time.Now
	}
	expiresAt := time.Unix(request.ExpiresAtUnix, 0)
	if !expiresAt.After(now()) {
		return nil, status.Error(codes.InvalidArgument, "expires_at_unix must be in the future")
	}
	if expiresAt.After(now().Add(24 * time.Hour)) {
		return nil, status.Error(codes.InvalidArgument, "expires_at_unix must be within 24 hours")
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	reminderID, err := installid.NewUUIDv4()
	if err != nil {
		zap.S().Errorw("uuid failed",
			"component", "firebase",
			"action", "create_arrival_reminder",
			"event", "uuid_failed",
			"install", request.InstallId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to create reminder ID")
	}
	stored := FirebaseArrivalReminder{
		ReminderID: reminderID, InstallID: request.InstallId, RouteType: request.RouteType, RouteKey: request.RouteKey,
		StopKey: request.StopKey, Direction: request.Direction, LeadMinutes: request.LeadMinutes,
		ExpiresAt: expiresAt, Status: ReminderPending, Plate: plate, AlightEvent: alightEvent,
	}
	// Rail arrival times are known at creation, so fire on a schedule (arrival
	// minus lead). Bus has no known arrival time and fires off the live ETA, so
	// it leaves fire_at NULL and is dispatched from busEta instead.
	if request.RouteType == "tra" || request.RouteType == "thsr" {
		fireAt := expiresAt.Add(-time.Duration(request.LeadMinutes) * time.Minute)
		stored.FireAt = &fireAt
	}
	if err := s.store.CreateArrivalReminder(ctx, stored); err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "create_arrival_reminder",
			"event", "store_failed",
			"install", request.InstallId,
			"err", err,
		)
		if errors.Is(err, ErrReminderLimitReached) {
			return nil, status.Error(codes.ResourceExhausted, "too many active arrival reminders")
		}
		if errors.Is(err, ErrReminderDuplicate) {
			return nil, status.Error(codes.AlreadyExists, "arrival reminder already exists")
		}
		return nil, status.Error(codes.Internal, "failed to save arrival reminder")
	}
	s.claimReminderDemand(ctx, stored)
	return &pb.ArrivalReminder{
		ReminderId: reminderID, InstallId: request.InstallId, RouteType: request.RouteType, RouteKey: request.RouteKey,
		StopKey: request.StopKey, Direction: request.Direction, LeadMinutes: request.LeadMinutes, ExpiresAtUnix: request.ExpiresAtUnix,
		Plate: plate,
	}, nil
}

// CancelArrivalReminder cancels a caller's pending reminder. It returns NotFound
// when no matching pending reminder exists (already fired, already cancelled, or
// owned by a different install). The caller is authorized first.
func (s *FirebaseServer) CancelArrivalReminder(ctx context.Context, request *pb.CancelArrivalReminderRequest) (*pb.Ack, error) {
	if !installid.ValidText(request.GetReminderId(), 64) || !installid.ValidText(request.GetInstallId(), 128) {
		return nil, status.Error(codes.InvalidArgument, "reminder_id and install_id are required")
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	cancelled, err := s.store.CancelArrivalReminder(ctx, request.ReminderId, request.InstallId)
	if err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "cancel_arrival_reminder",
			"event", "store_failed",
			"install", request.InstallId,
			"reminder", request.ReminderId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to cancel arrival reminder")
	}
	if !cancelled {
		return nil, status.Error(codes.NotFound, "pending arrival reminder not found")
	}
	return &pb.Ack{Ok: true}, nil
}

// ListDeviceState returns the stored preferences for a device. It returns
// NotFound when the install has no row. As with UpsertDevice, the fcm_token is
// stripped from the response.
func (s *FirebaseServer) ListDeviceState(ctx context.Context, request *pb.DeviceRequest) (*pb.DeviceState, error) {
	if !installid.ValidText(request.GetInstallId(), 128) {
		return nil, status.Error(codes.InvalidArgument, "install_id is required")
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	state, err := s.store.ListDeviceState(ctx, request.InstallId)
	if errors.Is(err, errFirebaseNotFound) {
		return nil, status.Error(codes.NotFound, "device not found")
	}
	if err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "list_device_state",
			"event", "store_failed",
			"install", request.InstallId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to load device")
	}
	state.Identity.FcmToken = ""
	return state, nil
}

func (s *FirebaseServer) authorizeInstall(ctx context.Context, installID string) error {
	return installid.Authorize(ctx, s.store, installID)
}

func validAlightEvent(event string) bool {
	switch event {
	case "", "lead", "alight":
		return true
	}
	return false
}

func validNormalizedPlate(plate string) bool {
	if plate == "" {
		return true
	}
	if len(plate) > 32 || plate[0] == '-' || plate[len(plate)-1] == '-' {
		return false
	}
	previousHyphen := false
	for _, char := range plate {
		switch {
		case char >= 'A' && char <= 'Z', char >= '0' && char <= '9':
			previousHyphen = false
		case char == '-' && !previousHyphen:
			previousHyphen = true
		default:
			return false
		}
	}
	return true
}

func validRoute(routeType string) bool {
	switch routeType {
	case "bus", "mrt", "tra", "thsr":
		return true
	default:
		return false
	}
}

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

func (s *FirebaseServer) claimReminderDemand(
	ctx context.Context,
	reminder FirebaseArrivalReminder,
) {
	if s.live == nil || reminder.RouteType != "bus" {
		return
	}
	city := shared.CityFromUID(reminder.RouteKey)
	if city == "" {
		return
	}
	now := s.now
	if now == nil {
		now = time.Now
	}
	ttl := reminder.ExpiresAt.Sub(now())
	if ttl <= 0 {
		return
	}
	s.live.Touch(ctx, shared.LiveDemandKey("bus_eta", city), ttl)
}

// NewFirebaseServer wires the device store, the clock, and the live source the
// reminder demand gate touches.
func NewFirebaseServer(store firebasePersistence, now func() time.Time, live livestream.LiveSource) *FirebaseServer {
	return &FirebaseServer{store: store, now: now, live: live}
}
