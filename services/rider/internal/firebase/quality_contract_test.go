package firebase

import (
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	pgxmock "github.com/pashagolub/pgxmock/v4"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestDeviceValidationKeepsPushOptionalAndRejectsMissingToken(t *testing.T) {
	for _, tc := range []struct {
		platform, token string
		enabled         bool
		code            codes.Code
	}{
		{"iOS", "", false, codes.OK}, {"android", "token", true, codes.OK}, {"ios", "", true, codes.InvalidArgument}, {"desktop", "", false, codes.InvalidArgument},
	} {
		identity := &pb.DeviceIdentity{InstallId: "install", Platform: tc.platform, FcmToken: tc.token}
		err := validateDevice(identity, &pb.DevicePrefs{PushEnabled: tc.enabled})
		if status.Code(err) != tc.code {
			t.Fatalf("%+v: %v", tc, err)
		}
	}
}

func TestReminderAndSubscriptionValidationRejectsInvalidPublicFields(t *testing.T) {
	valid := func() *pb.CreateArrivalReminderRequest {
		return &pb.CreateArrivalReminderRequest{InstallId: "install", RouteType: "bus", RouteKey: "route", StopKey: "stop", Direction: "0", LeadMinutes: 1}
	}
	for _, alter := range []func(*pb.CreateArrivalReminderRequest){func(r *pb.CreateArrivalReminderRequest) { r.InstallId = "" }, func(r *pb.CreateArrivalReminderRequest) { r.RouteType = "unknown" }, func(r *pb.CreateArrivalReminderRequest) { r.RouteKey = "" }, func(r *pb.CreateArrivalReminderRequest) { r.StopKey = "" }, func(r *pb.CreateArrivalReminderRequest) { r.Direction = "" }, func(r *pb.CreateArrivalReminderRequest) { r.Direction = "2" }, func(r *pb.CreateArrivalReminderRequest) { r.LeadMinutes = 0 }, func(r *pb.CreateArrivalReminderRequest) { r.LeadMinutes = 121 }} {
		request := valid()
		alter(request)
		if status.Code(validateReminderFields(request)) != codes.InvalidArgument {
			t.Fatalf("accepted %v", request)
		}
	}
	request := valid()
	request.RouteType = "mrt"
	if status.Code(validateReminderFields(request)) != codes.FailedPrecondition {
		t.Fatal("metro accepted for generic reminder")
	}
	if err := validateRouteSubscriptionRequest(&pb.RouteSubscriptionsRequest{InstallId: "install", Subscriptions: make([]*pb.RouteSubscription, 1001)}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("oversized subscriptions %v", err)
	}
	if err := validateRouteSubscriptionRequest(&pb.RouteSubscriptionsRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("empty install %v", err)
	}
}

func TestFirebaseStoreReplacesRoutesAndReadsPublicDeviceState(t *testing.T) {
	mock, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer mock.Close()
	store := &firebaseStore{db: mock}
	ctx := context.Background()
	scope := []*pb.RouteSubscription{{RouteType: "bus", RouteKey: "route"}, {RouteType: "tra", RouteKey: "*"}}
	mock.ExpectExec("WITH desired AS").WithArgs("install", []string{"bus", "tra"}, []string{"route", "*"}).WillReturnResult(pgxmock.NewResult("INSERT", 2))
	if err := store.ReplaceRouteSubscriptions(ctx, "install", scope); err != nil {
		t.Fatal(err)
	}
	mock.ExpectExec("WITH desired AS").WithArgs("install", []string{}, []string{}).WillReturnResult(pgxmock.NewResult("INSERT", 0))
	if err := store.ReplaceRouteSubscriptions(ctx, "install", nil); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name      string
		err, want error
	}{{"found", nil, nil}, {"missing", pgx.ErrNoRows, errFirebaseNotFound}, {"failure", errors.New("read failed"), nil}} {
		query := mock.ExpectQuery("SELECT platform, app_version, push_enabled").WithArgs("install")
		if tc.err != nil {
			query.WillReturnError(tc.err)
		} else {
			query.WillReturnRows(pgxmock.NewRows([]string{"platform", "app_version", "push_enabled"}).AddRow("ios", "1.0", true))
		}
		state, err := store.ListDeviceState(ctx, "install")
		want := tc.want
		if tc.name == "failure" {
			want = tc.err
		}
		if !errors.Is(err, want) {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if tc.err == nil && !reflect.DeepEqual(state, &pb.DeviceState{Identity: &pb.DeviceIdentity{InstallId: "install", Platform: "ios", AppVersion: "1.0"}, Prefs: &pb.DevicePrefs{PushEnabled: true}}) {
			t.Fatalf("state=%v", state)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestRedisDemandStoresExpiryAndToleratesClosedClient(t *testing.T) {
	addr := os.Getenv("RIDER_REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("RIDER_REDIS_TEST_ADDR required")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 15})
	t.Cleanup(func() { _ = rc.Close() })
	ctx := context.Background()
	const key = "quality_firebase_demand"
	t.Cleanup(func() { rc.Del(ctx, key) })
	demand := RedisDemand{RC: rc}
	demand.Touch(ctx, key, time.Minute)
	if rc.Get(ctx, key).Val() != "1" {
		t.Fatal("demand missing")
	}
	if ttl := rc.TTL(ctx, key).Val(); ttl < 50*time.Second || ttl > time.Minute {
		t.Fatalf("ttl=%v", ttl)
	}
	rc.Del(ctx, key)
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	demand.Touch(ctx, key, time.Minute)
}

type failedDevicePersistence struct {
	fakeFirebasePersistence
	err error
}

func (s *failedDevicePersistence) UpsertDevice(context.Context, *pb.DeviceIdentity, *pb.DevicePrefs, []byte) (*pb.DeviceState, bool, error) {
	return nil, false, s.err
}
func (s *failedDevicePersistence) ReplaceRouteSubscriptions(context.Context, string, []*pb.RouteSubscription) error {
	return s.err
}
func (s *failedDevicePersistence) CancelArrivalReminder(context.Context, string, string) (bool, error) {
	return false, s.err
}
func (s *failedDevicePersistence) ListDeviceState(context.Context, string) (*pb.DeviceState, error) {
	return nil, s.err
}

func TestFirebaseRPCReportsStorageFailuresWithoutLeakingDeviceData(t *testing.T) {
	hash := sha256.Sum256([]byte(_testInstallSecret))
	store := &failedDevicePersistence{fakeFirebasePersistence: fakeFirebasePersistence{device: &pb.DeviceState{Identity: &pb.DeviceIdentity{InstallId: "install"}}, secretHash: hash[:]}, err: errors.New("database unavailable")}
	server := NewFirebaseServer(store, nil, nil)
	ctx := installationContext("install", _testInstallSecret)
	if _, err := server.UpsertDevice(ctx, &pb.UpsertDeviceRequest{Identity: &pb.DeviceIdentity{InstallId: "install", Platform: "ios"}, Prefs: &pb.DevicePrefs{}}); status.Code(err) != codes.Internal {
		t.Fatalf("upsert: %v", err)
	}
	if _, err := server.ReplaceRouteSubscriptions(ctx, &pb.RouteSubscriptionsRequest{InstallId: "install"}); status.Code(err) != codes.Internal {
		t.Fatalf("subscriptions: %v", err)
	}
	if _, err := server.CancelArrivalReminder(ctx, &pb.CancelArrivalReminderRequest{InstallId: "install", ReminderId: "reminder"}); status.Code(err) != codes.Internal {
		t.Fatalf("cancel: %v", err)
	}
	if _, err := server.ListDeviceState(ctx, &pb.DeviceRequest{InstallId: "install"}); status.Code(err) != codes.Internal {
		t.Fatalf("list: %v", err)
	}
	store.err = errFirebaseNotFound
	if _, err := server.ListDeviceState(ctx, &pb.DeviceRequest{InstallId: "install"}); status.Code(err) != codes.NotFound {
		t.Fatalf("list absent: %v", err)
	}
	if _, err := server.ListDeviceState(context.Background(), &pb.DeviceRequest{InstallId: "install"}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("list missing credential: %v", err)
	}
	if _, err := server.ListDeviceState(ctx, &pb.DeviceRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("list missing install: %v", err)
	}
	if err := server.validateReminderExpiry(time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("default clock: %v", err)
	}
	if err := server.validateReminderExpiry(time.Now().Add(25 * time.Hour)); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("long expiry: %v", err)
	}
}

func TestFirebaseStoreCancellationReportsOnlyExactlyOneChangedRow(t *testing.T) {
	mock, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer mock.Close()
	store := &firebaseStore{db: mock}
	ctx := context.Background()
	for _, count := range []int64{0, 1, 2} {
		mock.ExpectExec("UPDATE firebase_arrival_reminder.*WHERE reminder_id = \\$1 AND install_id = \\$2 AND status = 'pending'").WithArgs("reminder", "install").WillReturnResult(pgxmock.NewResult("UPDATE", count))
		got, err := store.CancelArrivalReminder(ctx, "reminder", "install")
		if err != nil || got != (count == 1) {
			t.Fatalf("owned cancellation %d: %v %v", count, got, err)
		}
		mock.ExpectExec("UPDATE firebase_arrival_reminder.*WHERE reminder_id = \\$1 AND status = 'pending'").WithArgs("reminder").WillReturnResult(pgxmock.NewResult("UPDATE", count))
		got, err = store.CancelArrivalReminderByID(ctx, "reminder")
		if err != nil || got != (count == 1) {
			t.Fatalf("ID cancellation %d: %v %v", count, got, err)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
