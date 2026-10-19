package firebase

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestStoreInstallationCredentialMatchingAndReadErrors(t *testing.T) {
	for _, tc := range []struct {
		name             string
		stored, provided []byte
		err              error
		want             bool
	}{{"matching", []byte("secret"), []byte("secret"), nil, true}, {"different", []byte("secret"), []byte("SECRET"), nil, false}, {"different length", []byte("secret"), []byte("short"), nil, false}, {"missing", nil, []byte("secret"), pgx.ErrNoRows, false}, {"database", nil, []byte("secret"), errors.New("read failed"), false}} {
		t.Run(tc.name, func(t *testing.T) {
			m, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer m.Close()
			expect := m.ExpectQuery("SELECT install_secret_hash FROM firebase_device WHERE install_id").WithArgs("install")
			if tc.err != nil {
				expect.WillReturnError(tc.err)
			} else {
				expect.WillReturnRows(pgxmock.NewRows([]string{"install_secret_hash"}).AddRow(tc.stored))
			}
			got, err := (&firebaseStore{db: m}).AuthorizeInstall(context.Background(), "install", tc.provided)
			if got != tc.want {
				t.Fatalf("authorized=%v", got)
			}
			wantErr := tc.err
			if errors.Is(wantErr, pgx.ErrNoRows) {
				wantErr = nil
			}
			if !errors.Is(err, wantErr) {
				t.Fatalf("error=%v", err)
			}
			if err := m.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestStoreReminderQuotaBoundaryAndTransactionFailures(t *testing.T) {
	sentinel := errors.New("database unavailable")
	for _, tc := range []struct {
		name   string
		fail   string
		active int
		want   error
	}{{"begin", "begin", 0, sentinel}, {"lock", "lock", 0, sentinel}, {"insert", "insert", 0, sentinel}, {"count", "count", 0, sentinel}, {"duplicate", "", 49, ErrReminderDuplicate}, {"limit", "", 50, ErrReminderLimitReached}, {"above limit", "", 51, ErrReminderLimitReached}} {
		t.Run(tc.name, func(t *testing.T) {
			m, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer m.Close()
			store := &firebaseStore{db: m}
			at := time.Now().UTC()
			r := FirebaseArrivalReminder{ReminderID: "r", InstallID: "install", RouteType: "bus", RouteKey: "route", StopKey: "stop", Direction: "1", LeadMinutes: 5, ExpiresAt: at, Status: ReminderPending, Plate: "AA-1", AlightEvent: "lead"}
			if tc.fail == "begin" {
				m.ExpectBegin().WillReturnError(sentinel)
			} else {
				m.ExpectBegin()
				lock := m.ExpectExec("SELECT pg_advisory_xact_lock").WithArgs("install")
				if tc.fail == "lock" {
					lock.WillReturnError(sentinel)
				} else {
					lock.WillReturnResult(pgxmock.NewResult("SELECT", 1))
					insert := m.ExpectExec("INSERT INTO firebase_arrival_reminder").WithArgs("r", "install", "bus", "route", "stop", "1", int32(5), (*time.Time)(nil), at, ReminderPending, "AA-1", "lead")
					if tc.fail == "insert" {
						insert.WillReturnError(sentinel)
					} else {
						insert.WillReturnResult(pgxmock.NewResult("INSERT", 0))
						count := m.ExpectQuery("SELECT count\\(\\*\\) FROM firebase_arrival_reminder").WithArgs("install")
						if tc.fail == "count" {
							count.WillReturnError(sentinel)
						} else {
							count.WillReturnRows(pgxmock.NewRows([]string{"count"}).AddRow(tc.active))
						}
					}
				}
				m.ExpectRollback()
			}
			if err := store.CreateArrivalReminder(context.Background(), r); !errors.Is(err, tc.want) {
				t.Fatalf("store error=%v want=%v", err, tc.want)
			}
			if err := m.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
