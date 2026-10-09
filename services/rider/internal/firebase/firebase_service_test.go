package firebase

import (
	"context"
	"crypto/sha256"
	"strings"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	_testInstallSecret  = "0123456789abcdef0123456789abcdef"
	_wrongInstallSecret = "fedcba9876543210fedcba9876543210"
)

type fakeFirebasePersistence struct {
	device        *pb.DeviceState
	subscriptions []*pb.RouteSubscription
	subscribedBy  string
	reminder      FirebaseArrivalReminder
	cancelledID   string
	cancelledBy   string
	secretHash    []byte
	cancelMissing bool
}

func (f *fakeFirebasePersistence) UpsertDevice(_ context.Context, identity *pb.DeviceIdentity, prefs *pb.DevicePrefs, secretHash []byte) (*pb.DeviceState, bool, error) {
	if len(f.secretHash) != 0 && string(f.secretHash) != string(secretHash) {
		return nil, false, nil
	}
	f.secretHash = append([]byte(nil), secretHash...)
	f.device = &pb.DeviceState{Identity: identity, Prefs: prefs}
	return f.device, true, nil
}

func (f *fakeFirebasePersistence) AuthorizeInstall(_ context.Context, installID string, secretHash []byte) (bool, error) {
	return f.device != nil && f.device.Identity.InstallId == installID && string(f.secretHash) == string(secretHash), nil
}

func (f *fakeFirebasePersistence) ReplaceRouteSubscriptions(_ context.Context, installID string, subscriptions []*pb.RouteSubscription) error {
	f.subscribedBy, f.subscriptions = installID, subscriptions
	return nil
}

func (f *fakeFirebasePersistence) CreateArrivalReminder(_ context.Context, reminder FirebaseArrivalReminder) error {
	f.reminder = reminder
	return nil
}

func (f *fakeFirebasePersistence) CancelArrivalReminder(_ context.Context, reminderID, installID string) (bool, error) {
	f.cancelledID, f.cancelledBy = reminderID, installID
	return !f.cancelMissing, nil
}

func (f *fakeFirebasePersistence) ListDeviceState(_ context.Context, installID string) (*pb.DeviceState, error) {
	if f.device == nil || f.device.Identity.InstallId != installID {
		return nil, errFirebaseNotFound
	}
	return f.device, nil
}

func TestFirebaseServiceDeviceSubscriptionAndReminder(t *testing.T) {
	store := &fakeFirebasePersistence{}
	now := time.Unix(1_800_000_000, 0)
	server := &FirebaseServer{store: store, now: func() time.Time { return now }}

	ctx := installationContext("install-1", _testInstallSecret)
	state, err := server.UpsertDevice(ctx, &pb.UpsertDeviceRequest{
		Identity: &pb.DeviceIdentity{InstallId: "install-1", FcmToken: "token", Platform: "android", AppVersion: "1.0.0"},
		Prefs:    &pb.DevicePrefs{PushEnabled: true},
	})
	if err != nil || state.GetIdentity().GetInstallId() != "install-1" {
		t.Fatalf("UpsertDevice() = (%v, %v)", state, err)
	}
	wantHash := sha256.Sum256([]byte(_testInstallSecret))
	if string(store.secretHash) != string(wantHash[:]) || state.GetIdentity().GetFcmToken() != "" {
		t.Fatalf("secret hash or response token is unsafe: hash=%x state=%v", store.secretHash, state)
	}
	store.device.Identity.FcmToken = "private-token"
	listed, err := server.ListDeviceState(ctx, &pb.DeviceRequest{InstallId: "install-1"})
	if err != nil || listed.GetIdentity().GetFcmToken() != "" {
		t.Fatalf("ListDeviceState() = (%v, %v), token must be blank", listed, err)
	}

	// Every route_type the alert path can dispatch must be storable, including
	// the "*" line-wide marker a rail-station 收藏 resolves to.
	scope := []*pb.RouteSubscription{
		{RouteType: "bus", RouteKey: "route-1"},
		{RouteType: "mrt", RouteKey: "BL"},
		{RouteType: "tra", RouteKey: "*"},
		{RouteType: "thsr", RouteKey: "*"},
	}
	if _, err = server.ReplaceRouteSubscriptions(ctx, &pb.RouteSubscriptionsRequest{InstallId: "install-1", Subscriptions: scope}); err != nil {
		t.Fatalf("ReplaceRouteSubscriptions() error = %v", err)
	}
	if len(store.subscriptions) != len(scope) {
		t.Fatalf("stored scope = %v, want %v", store.subscriptions, scope)
	}
	// Clearing every 收藏 must clear the stored scope, not leave the last set
	// standing — that is the ghost-subscription bug this replaces.
	if _, err = server.ReplaceRouteSubscriptions(ctx, &pb.RouteSubscriptionsRequest{InstallId: "install-1"}); err != nil || len(store.subscriptions) != 0 {
		t.Fatalf("clearing scope: error = %v, stored = %v", err, store.subscriptions)
	}

	expires := now.Add(time.Hour)
	reminder, err := server.CreateArrivalReminder(ctx, &pb.CreateArrivalReminderRequest{
		InstallId: "install-1", RouteType: "bus", RouteKey: "route-1", StopKey: "stop-1",
		Direction: "0", LeadMinutes: 5, ExpiresAtUnix: expires.Unix(),
	})
	if err != nil {
		t.Fatalf("CreateArrivalReminder() error = %v", err)
	}
	if reminder.GetReminderId() == "" || store.reminder.Status != ReminderPending || store.reminder.FireAt != nil || !store.reminder.ExpiresAt.Equal(expires) {
		t.Fatalf("stored reminder = %#v, response = %v", store.reminder, reminder)
	}

	_, err = server.CancelArrivalReminder(ctx, &pb.CancelArrivalReminderRequest{ReminderId: reminder.ReminderId, InstallId: "install-1"})
	if err != nil || store.cancelledID != reminder.ReminderId || store.cancelledBy != "install-1" {
		t.Fatalf("CancelArrivalReminder() error = %v, id = %q, owner = %q", err, store.cancelledID, store.cancelledBy)
	}

	// Rail reminders fire on a schedule: the server derives fire_at = arrival
	// (expires_at) − lead so the reminder cron can dispatch it without a live ETA.
	railExpires := now.Add(time.Hour)
	railReminder, err := server.CreateArrivalReminder(ctx, &pb.CreateArrivalReminderRequest{
		InstallId: "install-1", RouteType: "tra", RouteKey: "1120", StopKey: "南港",
		Direction: "0", LeadMinutes: 3, ExpiresAtUnix: railExpires.Unix(),
	})
	if err != nil {
		t.Fatalf("CreateArrivalReminder(tra) error = %v", err)
	}
	wantFireAt := railExpires.Add(-3 * time.Minute)
	if railReminder.GetReminderId() == "" || store.reminder.RouteType != "tra" ||
		store.reminder.FireAt == nil || !store.reminder.FireAt.Equal(wantFireAt) {
		t.Fatalf("stored rail reminder = %#v", store.reminder)
	}
}

func TestFirebaseServiceNormalizesArrivalReminderPlate(t *testing.T) {
	store := &fakeFirebasePersistence{
		device: &pb.DeviceState{Identity: &pb.DeviceIdentity{InstallId: "install-1"}},
	}
	wantHash := sha256.Sum256([]byte(_testInstallSecret))
	store.secretHash = wantHash[:]
	now := time.Unix(1_800_000_000, 0)
	server := &FirebaseServer{store: store, now: func() time.Time { return now }}

	reminder, err := server.CreateArrivalReminder(
		installationContext("install-1", _testInstallSecret),
		&pb.CreateArrivalReminderRequest{
			InstallId: "install-1", RouteType: "bus", RouteKey: "route-1", StopKey: "stop-1",
			Direction: "0", LeadMinutes: 5, ExpiresAtUnix: now.Add(time.Hour).Unix(), Plate: "  kka-1288  ",
		},
	)
	if err != nil {
		t.Fatalf("CreateArrivalReminder() error = %v", err)
	}
	if store.reminder.Plate != "KKA-1288" || reminder.GetPlate() != "KKA-1288" {
		t.Fatalf("stored plate = %q, response plate = %q, want normalized KKA-1288", store.reminder.Plate, reminder.GetPlate())
	}
}

func TestFirebaseServiceRejectsInvalidArrivalReminderPlate(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	for _, plate := range []string{"KKA/1288", "-KKA1288", "KKA--1288", strings.Repeat("A", 33)} {
		t.Run(plate, func(t *testing.T) {
			store := &fakeFirebasePersistence{}
			server := &FirebaseServer{store: store, now: func() time.Time { return now }}
			_, err := server.CreateArrivalReminder(context.Background(), &pb.CreateArrivalReminderRequest{
				InstallId: "install-1", RouteType: "bus", RouteKey: "route-1", StopKey: "stop-1",
				Direction: "0", LeadMinutes: 5, ExpiresAtUnix: now.Add(time.Hour).Unix(), Plate: plate,
			})
			if status.Code(err) != codes.InvalidArgument {
				t.Fatalf("plate %q code = %v, want %v", plate, status.Code(err), codes.InvalidArgument)
			}
			if store.reminder.ReminderID != "" {
				t.Fatalf("invalid plate %q reached persistence: %#v", plate, store.reminder)
			}
		})
	}
}

func TestFirebaseServiceRejectsWrongInstallationCredential(t *testing.T) {
	store := &fakeFirebasePersistence{}
	server := &FirebaseServer{store: store, now: time.Now}
	request := &pb.UpsertDeviceRequest{
		Identity: &pb.DeviceIdentity{InstallId: "install-1", Platform: "ios"},
		Prefs:    &pb.DevicePrefs{},
	}
	if _, err := server.UpsertDevice(installationContext("install-1", _testInstallSecret), request); err != nil {
		t.Fatal(err)
	}
	if _, err := server.UpsertDevice(installationContext("install-1", _wrongInstallSecret), request); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("upsert conflict code = %v, want %v", status.Code(err), codes.PermissionDenied)
	}
	_, err := server.ReplaceRouteSubscriptions(installationContext("install-1", _wrongInstallSecret), &pb.RouteSubscriptionsRequest{
		InstallId: "install-1", Subscriptions: []*pb.RouteSubscription{{RouteType: "bus", RouteKey: "route-1"}},
	})
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("wrong secret code = %v, want %v", status.Code(err), codes.PermissionDenied)
	}
	_, err = server.ReplaceRouteSubscriptions(installationContext("other-install", _testInstallSecret), &pb.RouteSubscriptionsRequest{
		InstallId: "install-1", Subscriptions: []*pb.RouteSubscription{{RouteType: "bus", RouteKey: "route-1"}},
	})
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("cross-install code = %v, want %v", status.Code(err), codes.PermissionDenied)
	}
}

// The credential gate must reject requests that carry no installation metadata
// at all, or a secret below the 32-byte minimum — both would otherwise let an
// anonymous caller mutate another install's subscriptions and reminders.
func TestFirebaseServiceRejectsMissingOrShortCredentials(t *testing.T) {
	store := &fakeFirebasePersistence{}
	server := &FirebaseServer{store: store, now: time.Now}
	if _, err := server.UpsertDevice(installationContext("install-1", _testInstallSecret), &pb.UpsertDeviceRequest{
		Identity: &pb.DeviceIdentity{InstallId: "install-1", Platform: "ios"},
		Prefs:    &pb.DevicePrefs{},
	}); err != nil {
		t.Fatal(err)
	}

	subscription := &pb.RouteSubscriptionsRequest{
		InstallId: "install-1", Subscriptions: []*pb.RouteSubscription{{RouteType: "bus", RouteKey: "route-1"}},
	}
	tests := []struct {
		name string
		ctx  context.Context
	}{
		{"no metadata", context.Background()},
		{"secret below minimum length", installationContext("install-1", "short-secret")},
		{"metadata install mismatch", installationContext("install-2", _testInstallSecret)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := server.ReplaceRouteSubscriptions(tt.ctx, subscription)
			if status.Code(err) != codes.PermissionDenied {
				t.Fatalf("code = %v, want %v", status.Code(err), codes.PermissionDenied)
			}
			_, err = server.CancelArrivalReminder(tt.ctx, &pb.CancelArrivalReminderRequest{ReminderId: "id", InstallId: "install-1"})
			if status.Code(err) != codes.PermissionDenied {
				t.Fatalf("cancel code = %v, want %v", status.Code(err), codes.PermissionDenied)
			}
		})
	}
	if store.subscriptions != nil || store.cancelledID != "" {
		t.Fatalf("store mutated by unauthorized calls: sub=%v cancelled=%q", store.subscriptions, store.cancelledID)
	}
}

// Cancelling a reminder that is not pending for this install (already fired,
// cancelled, or owned by someone else) must surface NotFound, not silent success.
func TestFirebaseServiceCancelReminderNotFound(t *testing.T) {
	store := &fakeFirebasePersistence{cancelMissing: true}
	server := &FirebaseServer{store: store, now: time.Now}
	ctx := installationContext("install-1", _testInstallSecret)
	if _, err := server.UpsertDevice(ctx, &pb.UpsertDeviceRequest{
		Identity: &pb.DeviceIdentity{InstallId: "install-1", Platform: "ios"},
		Prefs:    &pb.DevicePrefs{},
	}); err != nil {
		t.Fatal(err)
	}
	_, err := server.CancelArrivalReminder(ctx, &pb.CancelArrivalReminderRequest{ReminderId: "gone", InstallId: "install-1"})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("code = %v, want %v", status.Code(err), codes.NotFound)
	}
}

// Older app builds send Dart's TargetPlatform.iOS.name ("iOS"), which the
// firebase_device CHECK constraint rejects; the server lowercases it.
func TestFirebaseServiceUpsertDeviceLowercasesPlatform(t *testing.T) {
	store := &fakeFirebasePersistence{}
	server := &FirebaseServer{store: store, now: time.Now}
	state, err := server.UpsertDevice(installationContext("install-1", _testInstallSecret), &pb.UpsertDeviceRequest{
		Identity: &pb.DeviceIdentity{InstallId: "install-1", FcmToken: "token", Platform: "iOS"},
		Prefs:    &pb.DevicePrefs{PushEnabled: true},
	})
	if err != nil {
		t.Fatalf("UpsertDevice() error = %v", err)
	}
	if got := state.GetIdentity().GetPlatform(); got != "ios" {
		t.Fatalf("platform = %q, want %q", got, "ios")
	}
}

func installationContext(installID, secret string) context.Context {
	return metadata.NewIncomingContext(context.Background(), metadata.Pairs(
		installid.MetadataKey, installID,
		installid.SecretMetadataKey, secret,
	))
}

func TestFirebaseServiceValidation(t *testing.T) {
	server := &FirebaseServer{store: &fakeFirebasePersistence{}, now: time.Now}
	tests := []struct {
		name string
		call func() error
		want codes.Code
	}{
		{"missing identity", func() error {
			_, err := server.UpsertDevice(context.Background(), &pb.UpsertDeviceRequest{})
			return err
		}, codes.InvalidArgument},
		{"bad platform", func() error {
			_, err := server.UpsertDevice(context.Background(), &pb.UpsertDeviceRequest{Identity: &pb.DeviceIdentity{InstallId: "a", FcmToken: "b", Platform: "web"}, Prefs: &pb.DevicePrefs{}})
			return err
		}, codes.InvalidArgument},
		{"missing install", func() error {
			_, err := server.ReplaceRouteSubscriptions(context.Background(), &pb.RouteSubscriptionsRequest{})
			return err
		}, codes.InvalidArgument},
		{"unknown subscription route type", func() error {
			_, err := server.ReplaceRouteSubscriptions(context.Background(), &pb.RouteSubscriptionsRequest{
				InstallId: "a", Subscriptions: []*pb.RouteSubscription{{RouteType: "bike", RouteKey: "r"}},
			})
			return err
		}, codes.InvalidArgument},
		{"expired reminder", func() error {
			_, err := server.CreateArrivalReminder(context.Background(), &pb.CreateArrivalReminderRequest{InstallId: "a", RouteType: "bus", RouteKey: "r", StopKey: "s", Direction: "0", LeadMinutes: 5, ExpiresAtUnix: time.Now().Add(-time.Minute).Unix()})
			return err
		}, codes.InvalidArgument},
		{"unsupported mrt reminder", func() error {
			_, err := server.CreateArrivalReminder(context.Background(), &pb.CreateArrivalReminderRequest{InstallId: "a", RouteType: "mrt", RouteKey: "r", StopKey: "s", Direction: "0", LeadMinutes: 5, ExpiresAtUnix: time.Now().Add(time.Hour).Unix()})
			return err
		}, codes.FailedPrecondition},
		{"missing cancel owner", func() error {
			_, err := server.CancelArrivalReminder(context.Background(), &pb.CancelArrivalReminderRequest{ReminderId: "id"})
			return err
		}, codes.InvalidArgument},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if code := status.Code(tt.call()); code != tt.want {
				t.Fatalf("code = %v, want %v", code, tt.want)
			}
		})
	}
}

// writeSelfSignedCertPair generates a throwaway self-signed certificate and
// key pair for exercising tls.LoadX509KeyPair, and returns their file paths.

// demandLiveSource is a livestream.LiveSource that records only the demand touches; the
// reminder path never reads or subscribes.
type demandLiveSource struct{ touches map[string]time.Duration }

var _ DemandToucher = (*demandLiveSource)(nil)

func (d *demandLiveSource) Get(context.Context, string) ([]byte, bool) { return nil, false }
func (d *demandLiveSource) ScanKeys(context.Context, string) []string  { return nil }
func (d *demandLiveSource) Subscribe(context.Context, string) (<-chan []byte, func(), error) {
	return nil, func() {}, nil
}

func (d *demandLiveSource) Touch(_ context.Context, key string, ttl time.Duration) {
	if d.touches == nil {
		d.touches = map[string]time.Duration{}
	}
	d.touches[key] = ttl
}

func TestCreateArrivalReminderClaimsBusCityDemand(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	live := &demandLiveSource{}
	store := &fakeFirebasePersistence{}
	server := &FirebaseServer{store: store, now: func() time.Time { return now }, live: live}
	ctx := installationContext("install-1", _testInstallSecret)
	if _, err := server.UpsertDevice(ctx, &pb.UpsertDeviceRequest{
		Identity: &pb.DeviceIdentity{
			InstallId: "install-1", FcmToken: "t", Platform: "android", AppVersion: "1.0.0",
		},
		Prefs: &pb.DevicePrefs{PushEnabled: true},
	}); err != nil {
		t.Fatalf("UpsertDevice() error = %v", err)
	}

	expires := now.Add(40 * time.Minute)
	if _, err := server.CreateArrivalReminder(ctx, &pb.CreateArrivalReminderRequest{
		InstallId: "install-1", RouteType: "bus", RouteKey: "ILA1234", StopKey: "S1",
		Direction: "0", LeadMinutes: 5, ExpiresAtUnix: expires.Unix(),
	}); err != nil {
		t.Fatalf("CreateArrivalReminder() error = %v", err)
	}

	got, ok := live.touches[shared.LiveDemandKey("bus_eta", "YilanCounty")]
	if !ok {
		t.Fatalf("touches = %v, want the Yilan bus demand key", live.touches)
	}
	if got != 40*time.Minute {
		t.Fatalf("demand TTL = %v, want the reminder's own 40m expiry", got)
	}
}

// TestCreateArrivalReminderSkipsRailDemand keeps rail out of the gate: rail
// reminders carry a fire_at and dispatch on a schedule, so they do not depend
// on any city staying at full polling cadence.
func TestCreateArrivalReminderSkipsRailDemand(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	live := &demandLiveSource{}
	store := &fakeFirebasePersistence{}
	server := &FirebaseServer{store: store, now: func() time.Time { return now }, live: live}
	ctx := installationContext("install-1", _testInstallSecret)
	if _, err := server.UpsertDevice(ctx, &pb.UpsertDeviceRequest{
		Identity: &pb.DeviceIdentity{
			InstallId: "install-1", FcmToken: "t", Platform: "android", AppVersion: "1.0.0",
		},
		Prefs: &pb.DevicePrefs{PushEnabled: true},
	}); err != nil {
		t.Fatalf("UpsertDevice() error = %v", err)
	}

	if _, err := server.CreateArrivalReminder(ctx, &pb.CreateArrivalReminderRequest{
		InstallId: "install-1", RouteType: "tra", RouteKey: "1234", StopKey: "S1",
		Direction: "0", LeadMinutes: 5, ExpiresAtUnix: now.Add(time.Hour).Unix(),
	}); err != nil {
		t.Fatalf("CreateArrivalReminder() error = %v", err)
	}
	if len(live.touches) != 0 {
		t.Fatalf("touches = %v, want none for a rail reminder", live.touches)
	}
}
