package firebase

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func firebaseContractAuthorize(t *testing.T, server *FirebaseServer) context.Context {
	t.Helper()
	ctx := installationContext("install-1", _testInstallSecret)
	_, err := server.UpsertDevice(ctx, &pb.UpsertDeviceRequest{Identity: &pb.DeviceIdentity{InstallId: "install-1", Platform: "android"}, Prefs: &pb.DevicePrefs{PushEnabled: false}})
	if err != nil {
		t.Fatal(err)
	}
	return ctx
}

func TestAuthenticatedDeviceMayReplaceExactlyOneThousandSubscriptions(t *testing.T) {
	store := &fakeFirebasePersistence{}
	server := NewFirebaseServer(store, time.Now, nil)
	ctx := firebaseContractAuthorize(t, server)
	scope := make([]*pb.RouteSubscription, 1000)
	for i := range scope {
		scope[i] = &pb.RouteSubscription{RouteType: "bus", RouteKey: fmt.Sprintf("route-%d", i)}
	}
	ack, err := server.ReplaceRouteSubscriptions(ctx, &pb.RouteSubscriptionsRequest{InstallId: "install-1", Subscriptions: scope})
	if err != nil || !ack.GetOk() || store.subscribedBy != "install-1" || !reflect.DeepEqual(store.subscriptions, scope) {
		t.Fatalf("exact quota replacement ack=%v err=%v stored=%d", ack, err, len(store.subscriptions))
	}
}

func TestRailReminderLeadIncludesOneAndOneHundredTwentyMinutes(t *testing.T) {
	for _, lead := range []int32{1, 120} {
		t.Run(fmt.Sprint(lead), func(t *testing.T) {
			store := &fakeFirebasePersistence{}
			now := time.Unix(1800000000, 0)
			expires := now.Add(3 * time.Hour)
			server := NewFirebaseServer(store, func() time.Time { return now }, nil)
			ctx := firebaseContractAuthorize(t, server)
			receipt, err := server.CreateArrivalReminder(ctx, &pb.CreateArrivalReminderRequest{InstallId: "install-1", RouteType: "tra", RouteKey: "1120", StopKey: "南港", Direction: "0", LeadMinutes: lead, ExpiresAtUnix: expires.Unix()})
			if err != nil {
				t.Fatal(err)
			}
			if receipt.GetLeadMinutes() != lead || store.reminder.LeadMinutes != lead || store.reminder.FireAt == nil || !store.reminder.FireAt.Equal(expires.Add(-time.Duration(lead)*time.Minute)) {
				t.Fatalf("lead=%d receipt=%v persisted=%+v", lead, receipt, store.reminder)
			}
		})
	}
}

func TestArrivalReminderPersistsPlateAlphabetAndLengthBoundaries(t *testing.T) {
	for _, plate := range []string{"A", "Z", "0", "9", strings.Repeat("A", 31) + "Z", " az-09 "} {
		t.Run(plate, func(t *testing.T) {
			store := &fakeFirebasePersistence{}
			now := time.Unix(1800000000, 0)
			server := NewFirebaseServer(store, func() time.Time { return now }, nil)
			ctx := firebaseContractAuthorize(t, server)
			receipt, err := server.CreateArrivalReminder(ctx, &pb.CreateArrivalReminderRequest{InstallId: "install-1", RouteType: "bus", RouteKey: "TPEroute", StopKey: "stop", Direction: "0", LeadMinutes: 1, ExpiresAtUnix: now.Add(time.Hour).Unix(), Plate: plate})
			if err != nil {
				t.Fatal(err)
			}
			want := strings.ToUpper(strings.TrimSpace(plate))
			if receipt.GetPlate() != want || store.reminder.Plate != want {
				t.Fatalf("plate=%q receipt=%q persisted=%q", plate, receipt.GetPlate(), store.reminder.Plate)
			}
		})
	}
}

type firebaseExpiresWhilePersisting struct {
	fakeFirebasePersistence
	clock *time.Time
}

func (s *firebaseExpiresWhilePersisting) CreateArrivalReminder(ctx context.Context, reminder FirebaseArrivalReminder) error {
	if err := s.fakeFirebasePersistence.CreateArrivalReminder(ctx, reminder); err != nil {
		return err
	}
	*s.clock = reminder.ExpiresAt
	return nil
}

func firebaseContractRedis(t *testing.T, key string) *redis.Client {
	t.Helper()
	addr := os.Getenv("RIDER_REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("RIDER_REDIS_TEST_ADDR required")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 15})
	if err := rc.Del(context.Background(), key).Err(); err != nil {
		_ = rc.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err(); _ = rc.Close() })
	return rc
}

func TestReminderExpiringDuringPersistenceDoesNotCreatePermanentDemand(t *testing.T) {
	key := shared.LiveDemandKey("bus_eta", "Taipei")
	rc := firebaseContractRedis(t, key)
	now := time.Unix(1800000000, 0)
	store := &firebaseExpiresWhilePersisting{clock: &now}
	server := NewFirebaseServer(store, func() time.Time { return now }, RedisDemand{RC: rc})
	ctx := firebaseContractAuthorize(t, server)
	expires := now.Add(time.Hour)
	receipt, err := server.CreateArrivalReminder(ctx, &pb.CreateArrivalReminderRequest{InstallId: "install-1", RouteType: "bus", RouteKey: "TPEroute", StopKey: "stop", Direction: "0", LeadMinutes: 1, ExpiresAtUnix: expires.Unix()})
	if err != nil || receipt.GetReminderId() == "" || !store.reminder.ExpiresAt.Equal(expires) {
		t.Fatalf("persisted reminder=%+v receipt=%v err=%v", store.reminder, receipt, err)
	}
	n, err := rc.Exists(ctx, key).Result()
	if err != nil || n != 0 {
		t.Fatalf("expired reminder produced demand key: exists=%d err=%v", n, err)
	}
}

func TestRedisDemandFailureDiagnosticKeepsOriginalCauseAndDemandKey(t *testing.T) {
	const key = "quality_firebase_demand_diagnostic"
	rc := firebaseContractRedis(t, key)
	core, logs := observer.New(zap.DebugLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(undo)
	demand := RedisDemand{RC: rc}
	demand.Touch(context.Background(), key, time.Minute)
	if rc.Get(context.Background(), key).Val() != "1" {
		t.Fatal("healthy demand write missing")
	}
	if entries := logs.FilterField(zap.String("action", "touch_demand")).All(); len(entries) != 0 {
		t.Fatalf("healthy write reported failure: %+v", entries)
	}
	if err := rc.Del(context.Background(), key).Err(); err != nil {
		t.Fatal(err)
	}
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	demand.Touch(context.Background(), key, time.Minute)
	for _, entry := range logs.All() {
		if entry.ContextMap()["action"] != "touch_demand" || entry.ContextMap()["key"] != key {
			continue
		}
		for _, field := range entry.Context {
			if err, ok := field.Interface.(error); field.Key == "err" && ok && errors.Is(err, redis.ErrClosed) {
				return
			}
		}
	}
	t.Fatalf("demand failure lost original cause/key: %+v", logs.All())
}
