// Package firebase owns device registration, notification preferences, and
// arrival reminders, plus App Check verification for the whole router. It is
// the device store every other device-scoped service authenticates against.
package firebase

import (
	"context"
	"errors"
	"strings"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
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
	live  DemandToucher
}

func (s *FirebaseServer) UpsertDevice(ctx context.Context, request *pb.UpsertDeviceRequest) (*pb.DeviceState, error) {
	identity, prefs := request.GetIdentity(), request.GetPrefs()
	if err := validateDevice(identity, prefs); err != nil {
		return nil, err
	}
	secretHash, err := installid.SecretHash(ctx, identity.InstallId)
	if err != nil {
		return nil, err
	}
	return s.upsertAuthorizedDevice(ctx, identity, prefs, secretHash)
}

func (s *FirebaseServer) upsertAuthorizedDevice(ctx context.Context, identity *pb.DeviceIdentity, prefs *pb.DevicePrefs, secretHash []byte) (*pb.DeviceState, error) {
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

func validDeviceIdentity(identity *pb.DeviceIdentity, prefs *pb.DevicePrefs) bool {
	return identity != nil && prefs != nil && installid.ValidText(identity.GetInstallId(), 128) && installid.ValidText(identity.GetPlatform(), 16)
}

func validateDevice(identity *pb.DeviceIdentity, prefs *pb.DevicePrefs) error {
	if !validDeviceIdentity(identity, prefs) {
		return status.Error(codes.InvalidArgument, "identity and preferences are required")
	}
	// Clients have sent mixed case here (Dart's TargetPlatform.iOS.name is
	// "iOS"); the firebase_device CHECK constraint only accepts lowercase.
	identity.Platform = strings.ToLower(identity.Platform)
	if !validDevicePlatform(identity.Platform) {
		return status.Error(codes.InvalidArgument, "platform must be android or ios")
	}
	if !validDevicePushToken(identity, prefs) {
		return status.Error(codes.InvalidArgument, "fcm_token is required when push is enabled")
	}
	return nil
}

func validDevicePlatform(platform string) bool { return platform == "android" || platform == "ios" }
func validDevicePushToken(identity *pb.DeviceIdentity, prefs *pb.DevicePrefs) bool {
	return !prefs.PushEnabled || installid.ValidText(identity.FcmToken, 4096)
}

func (s *FirebaseServer) ReplaceRouteSubscriptions(ctx context.Context, request *pb.RouteSubscriptionsRequest) (*pb.Ack, error) {
	if err := validateRouteSubscriptionRequest(request); err != nil {
		return nil, err
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	return s.saveRouteSubscriptions(ctx, request)
}

func (s *FirebaseServer) saveRouteSubscriptions(ctx context.Context, request *pb.RouteSubscriptionsRequest) (*pb.Ack, error) {
	if err := s.store.ReplaceRouteSubscriptions(ctx, request.InstallId, request.GetSubscriptions()); err != nil {
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

func validateRouteSubscriptionRequest(request *pb.RouteSubscriptionsRequest) error {
	// maxRouteSubscriptions bounds one device's 訂閱範圍. It is far above any
	// plausible 收藏 list and exists only so a malformed or hostile client
	// cannot make the server build an unbounded array.
	const maxRouteSubscriptions = 1000
	if !installid.ValidText(request.GetInstallId(), 128) {
		return status.Error(codes.InvalidArgument, "install_id is required")
	}
	subscriptions := request.GetSubscriptions()
	if len(subscriptions) > maxRouteSubscriptions {
		return status.Errorf(codes.InvalidArgument, "at most %d subscriptions", maxRouteSubscriptions)
	}
	if err := validateRouteSubscriptions(subscriptions); err != nil {
		return err
	}
	return nil
}

func validateRouteSubscriptions(subscriptions []*pb.RouteSubscription) error {
	for _, subscription := range subscriptions {
		if !validAlertRoute(subscription.GetRouteType()) || !installid.ValidText(subscription.GetRouteKey(), 256) {
			return status.Error(codes.InvalidArgument, "each subscription needs a known route_type and a route_key")
		}
	}
	return nil
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
	spec, err := s.validateReminderRequest(request)
	if err != nil {
		return nil, err
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	return s.createAuthorizedReminder(ctx, request, spec)
}

func (s *FirebaseServer) createAuthorizedReminder(ctx context.Context, request *pb.CreateArrivalReminderRequest, spec reminderSpec) (*pb.ArrivalReminder, error) {
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
	stored := buildArrivalReminder(request, reminderID, spec)
	if err := s.store.CreateArrivalReminder(ctx, stored); err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "create_arrival_reminder",
			"event", "store_failed",
			"install", request.InstallId,
			"err", err,
		)
		return nil, arrivalReminderStoreError(err)
	}
	s.claimReminderDemand(ctx, stored)
	return &pb.ArrivalReminder{
		ReminderId: reminderID, InstallId: request.InstallId, RouteType: request.RouteType, RouteKey: request.RouteKey,
		StopKey: request.StopKey, Direction: request.Direction, LeadMinutes: request.LeadMinutes, ExpiresAtUnix: request.ExpiresAtUnix,
		Plate: spec.plate,
	}, nil
}

type reminderSpec struct {
	plate, alightEvent string
	expiresAt          time.Time
}

func (s *FirebaseServer) validateReminderRequest(request *pb.CreateArrivalReminderRequest) (reminderSpec, error) {
	if err := validateReminderFields(request); err != nil {
		return reminderSpec{}, err
	}
	plate := strings.ToUpper(strings.TrimSpace(request.GetPlate()))
	if !validNormalizedPlate(plate) {
		return reminderSpec{}, status.Error(codes.InvalidArgument, "plate must contain only letters, digits, and single hyphen separators")
	}
	return s.reminderSpecForPlate(request, plate)
}

func (s *FirebaseServer) reminderSpecForPlate(request *pb.CreateArrivalReminderRequest, plate string) (reminderSpec, error) {
	alightEvent := request.GetAlightEvent()
	if !validAlightEvent(alightEvent) {
		return reminderSpec{}, status.Error(codes.InvalidArgument, "alight_event must be lead, alight, or empty")
	}
	expiresAt := time.Unix(request.ExpiresAtUnix, 0)
	if err := s.validateReminderExpiry(expiresAt); err != nil {
		return reminderSpec{}, err
	}
	return reminderSpec{plate: plate, alightEvent: alightEvent, expiresAt: expiresAt}, nil
}

func validateReminderFields(request *pb.CreateArrivalReminderRequest) error {
	if !validReminderIdentity(request) {
		return status.Error(codes.InvalidArgument, "install_id, route, stop, and direction are required")
	}
	switch request.RouteType {
	case "bus", "tra", "thsr":
	default:
		return status.Error(codes.FailedPrecondition, "arrival reminders are supported for bus and rail routes only")
	}
	return validateReminderTiming(request)
}

func validateReminderTiming(request *pb.CreateArrivalReminderRequest) error {
	if !validReminderDirection(request.Direction) {
		return status.Error(codes.InvalidArgument, "direction must be 0 or 1")
	}
	if !validReminderLead(request.LeadMinutes) {
		return status.Error(codes.InvalidArgument, "lead_minutes must be between 1 and 120")
	}
	return nil
}

func validReminderDirection(value string) bool { return value == "0" || value == "1" }
func validReminderLead(value int32) bool       { return value >= 1 && value <= 120 }

func validReminderIdentity(request *pb.CreateArrivalReminderRequest) bool {
	if !validReminderInstallation(request) {
		return false
	}
	for _, value := range []string{request.GetRouteKey(), request.GetStopKey()} {
		if !installid.ValidText(value, 256) {
			return false
		}
	}
	return installid.ValidText(request.GetDirection(), 32)
}

func validReminderInstallation(request *pb.CreateArrivalReminderRequest) bool {
	return installid.ValidText(request.GetInstallId(), 128) && validRoute(request.GetRouteType())
}

func (s *FirebaseServer) validateReminderExpiry(expiresAt time.Time) error {
	now := s.now
	if now == nil {
		now = time.Now
	}
	return validateReminderExpiryWithClock(expiresAt, now)
}

func validateReminderExpiryWithClock(expiresAt time.Time, now func() time.Time) error {
	if !expiresAt.After(now()) {
		return status.Error(codes.InvalidArgument, "expires_at_unix must be in the future")
	}
	if expiresAt.After(now().Add(24 * time.Hour)) {
		return status.Error(codes.InvalidArgument, "expires_at_unix must be within 24 hours")
	}
	return nil
}

func buildArrivalReminder(request *pb.CreateArrivalReminderRequest, reminderID string, spec reminderSpec) FirebaseArrivalReminder {
	stored := FirebaseArrivalReminder{
		ReminderID: reminderID, InstallID: request.InstallId, RouteType: request.RouteType, RouteKey: request.RouteKey,
		StopKey: request.StopKey, Direction: request.Direction, LeadMinutes: request.LeadMinutes,
		ExpiresAt: spec.expiresAt, Status: ReminderPending, Plate: spec.plate, AlightEvent: spec.alightEvent,
	}
	// Rail arrival times are known at creation, so fire on a schedule (arrival
	// minus lead). Bus has no known arrival time and fires off the live ETA, so
	// it leaves fire_at NULL and is dispatched from busEta instead.
	if request.RouteType == "tra" || request.RouteType == "thsr" {
		fireAt := spec.expiresAt.Add(-time.Duration(request.LeadMinutes) * time.Minute)
		stored.FireAt = &fireAt
	}
	return stored
}

func arrivalReminderStoreError(err error) error {
	if errors.Is(err, ErrReminderLimitReached) {
		return status.Error(codes.ResourceExhausted, "too many active arrival reminders")
	}
	if errors.Is(err, ErrReminderDuplicate) {
		return status.Error(codes.AlreadyExists, "arrival reminder already exists")
	}
	return status.Error(codes.Internal, "failed to save arrival reminder")
}

// CancelArrivalReminder cancels a caller's pending reminder. It returns NotFound
// when no matching pending reminder exists (already fired, already cancelled, or
// owned by a different install). The caller is authorized first.
func (s *FirebaseServer) CancelArrivalReminder(ctx context.Context, request *pb.CancelArrivalReminderRequest) (*pb.Ack, error) {
	if !validReminderOwner(request) {
		return nil, status.Error(codes.InvalidArgument, "reminder_id and install_id are required")
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	return s.cancelAuthorizedReminder(ctx, request)
}

func (s *FirebaseServer) cancelAuthorizedReminder(ctx context.Context, request *pb.CancelArrivalReminderRequest) (*pb.Ack, error) {
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

func validReminderOwner(request *pb.CancelArrivalReminderRequest) bool {
	return installid.ValidText(request.GetReminderId(), 64) && installid.ValidText(request.GetInstallId(), 128)
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
	return s.listAuthorizedDeviceState(ctx, request.InstallId)
}

func (s *FirebaseServer) listAuthorizedDeviceState(ctx context.Context, installID string) (*pb.DeviceState, error) {
	state, err := s.store.ListDeviceState(ctx, installID)
	if errors.Is(err, errFirebaseNotFound) {
		return nil, status.Error(codes.NotFound, "device not found")
	}
	if err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "list_device_state",
			"event", "store_failed",
			"install", installID,
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
	if !validPlateEdges(plate) {
		return false
	}
	return validPlateCharacters(plate)
}

func validPlateCharacters(plate string) bool {
	previousHyphen := false
	for _, char := range plate {
		valid, hyphen := validPlateCharacter(char, previousHyphen)
		if !valid {
			return false
		}
		previousHyphen = hyphen
	}
	return true
}

func validPlateCharacter(char rune, previousHyphen bool) (bool, bool) {
	if isPlateAlphaNumeric(char) {
		return true, false
	}
	if validPlateHyphen(char, previousHyphen) {
		return true, true
	}
	return false, false
}

func validPlateHyphen(char rune, previousHyphen bool) bool { return char == '-' && !previousHyphen }

func validPlateEdges(plate string) bool {
	return len(plate) <= 32 && plate[0] != '-' && plate[len(plate)-1] != '-'
}

func isPlateAlphaNumeric(char rune) bool {
	return (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9')
}

func validRoute(routeType string) bool {
	switch routeType {
	case "bus", "mrt", "tra", "thsr":
		return true
	default:
		return false
	}
}

// VerifyToken checks a Firebase App Check token via the Admin SDK. The context
// is unused because the underlying appcheck client verifies offline against
// cached public keys.

// GRPCTLSCredentialsFromEnv builds server TLS credentials when GRPC_TLS is
// enabled. It fails closed: GRPC_TLS=true without both cert and key paths
// is a startup error rather than a silent fall-back to plaintext.

func (s *FirebaseServer) claimReminderDemand(
	ctx context.Context,
	reminder FirebaseArrivalReminder,
) {
	if !s.reminderDemandEnabled(reminder) {
		return
	}
	city := shared.CityFromUID(reminder.RouteKey)
	if city == "" {
		return
	}
	s.touchReminderDemand(ctx, reminder, city)
}

func (s *FirebaseServer) reminderDemandEnabled(reminder FirebaseArrivalReminder) bool {
	return s.live != nil && reminder.RouteType == "bus"
}

func (s *FirebaseServer) touchReminderDemand(ctx context.Context, reminder FirebaseArrivalReminder, city string) {
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

// DemandToucher refreshes the bus ETA demand key a pending reminder keeps alive.
type DemandToucher interface {
	Touch(ctx context.Context, key string, ttl time.Duration)
}

// RedisDemand is the production DemandToucher. Its writes never shorten a
// longer demand TTL, so one reminder cannot cut another's. A failed write is
// counted and logged rather than returned: the reminder is already stored, and
// its city is then fetched only while other demand covers it.
type RedisDemand struct{ RC *redis.Client }

func (d RedisDemand) Touch(ctx context.Context, key string, ttl time.Duration) {
	if _, err := shared.TouchLiveDemand(ctx, d.RC, key, ttl); err != nil {
		obs.IncRedisError()
		zap.S().Warnw("failed", "component", "firebase", "action", "touch_demand", "event", "failed", "key", key, "err", err)
	}
}

// NewFirebaseServer wires the device store, the clock, and the live source the
// reminder demand gate touches.
func NewFirebaseServer(store firebasePersistence, now func() time.Time, live DemandToucher) *FirebaseServer {
	return &FirebaseServer{store: store, now: now, live: live}
}
