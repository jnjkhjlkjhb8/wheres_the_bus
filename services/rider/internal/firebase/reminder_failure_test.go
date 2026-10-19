package firebase

import (
	"context"
	"crypto/sha256"
	"errors"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type failedReminderPersistence struct {
	fakeFirebasePersistence
	err error
}

func (s *failedReminderPersistence) CreateArrivalReminder(context.Context, FirebaseArrivalReminder) error {
	return s.err
}

func TestCreateReminderMapsQuotaDuplicateAndStorageFailures(t *testing.T) {
	now := time.Unix(1800000000, 0)
	hash := sha256.Sum256([]byte(_testInstallSecret))
	for _, tc := range []struct {
		err  error
		code codes.Code
	}{{ErrReminderLimitReached, codes.ResourceExhausted}, {ErrReminderDuplicate, codes.AlreadyExists}, {errors.New("database unavailable"), codes.Internal}} {
		store := &failedReminderPersistence{fakeFirebasePersistence: fakeFirebasePersistence{device: &pb.DeviceState{Identity: &pb.DeviceIdentity{InstallId: "install"}}, secretHash: hash[:]}, err: tc.err}
		s := &FirebaseServer{store: store, now: func() time.Time { return now }}
		_, err := s.CreateArrivalReminder(installationContext("install", _testInstallSecret), &pb.CreateArrivalReminderRequest{InstallId: "install", RouteType: "bus", RouteKey: "route", StopKey: "stop", Direction: "0", LeadMinutes: 5, ExpiresAtUnix: now.Add(time.Hour).Unix()})
		if status.Code(err) != tc.code {
			t.Fatalf("storage=%v RPC=%v", tc.err, err)
		}
	}
}
