package firebase

import (
	"context"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestFirebaseStoreSQL(t *testing.T) {
	ctx := context.Background()
	mock, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer mock.Close()
	store := &firebaseStore{db: mock}
	hash := []byte("01234567890123456789012345678901")
	mock.ExpectExec("INSERT INTO firebase_device.*WHERE firebase_device.install_secret_hash = EXCLUDED.install_secret_hash").WithArgs("i", "tok", "android", "1", true, hash).WillReturnResult(pgxmock.NewResult("INSERT", 1))
	state, ok, err := store.UpsertDevice(ctx, &pb.DeviceIdentity{InstallId: "i", FcmToken: "tok", Platform: "android", AppVersion: "1"}, &pb.DevicePrefs{PushEnabled: true}, hash)
	if err != nil || !ok || state.GetIdentity().GetFcmToken() != "" {
		t.Fatalf("upsert = %#v, %v, %v", state, ok, err)
	}
	expires := time.Now().Add(time.Hour)
	mock.ExpectBegin()
	mock.ExpectExec("SELECT pg_advisory_xact_lock").WithArgs("i").WillReturnResult(pgxmock.NewResult("SELECT", 1))
	mock.ExpectExec("INSERT INTO firebase_arrival_reminder").WithArgs("r", "i", "bus", "route", "stop", "0", int32(5), (*time.Time)(nil), expires, ReminderPending, "", "").WillReturnResult(pgxmock.NewResult("INSERT", 1))
	mock.ExpectCommit()
	if err := store.CreateArrivalReminder(ctx, FirebaseArrivalReminder{ReminderID: "r", InstallID: "i", RouteType: "bus", RouteKey: "route", StopKey: "stop", Direction: "0", LeadMinutes: 5, ExpiresAt: expires, Status: ReminderPending}); err != nil {
		t.Fatal(err)
	}
}
