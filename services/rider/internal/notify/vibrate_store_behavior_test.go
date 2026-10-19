package notify

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/pashagolub/pgxmock/v4"
)

func TestMrtVibrateFailureReleasesOrStopsAfterInvalidationFailure(t *testing.T) {
	sendErr := errors.New("push unavailable")
	dbErr := errors.New("database unavailable")
	for _, tc := range []struct {
		name                      string
		invalid                   bool
		invalidateErr, releaseErr error
		wantRelease               bool
	}{{"transient", false, nil, nil, true}, {"invalid token", true, nil, nil, true}, {"invalidation failure", true, dbErr, nil, false}, {"release failure", false, nil, dbErr, true}} {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeNotificationStore{claimed: map[string]bool{}, invalidateErr: tc.invalidateErr, releaseErr: tc.releaseErr}
			sender := &fakeFCM{err: sendErr}
			d := NewDispatcher(store, sender)
			d.isInvalidFCMToken = func(error) bool { return tc.invalid }
			fired, err := d.FireMrtVibrate(context.Background(), MrtVibrateEvent{ReminderID: "r1", Token: "token", TrackID: "track", AlightEvent: "lead"})
			if fired || !errors.Is(err, sendErr) {
				t.Fatalf("fired=%v err=%v", fired, err)
			}
			if tc.invalidateErr != nil || tc.releaseErr != nil {
				if !errors.Is(err, dbErr) {
					t.Fatalf("storage error missing=%v", err)
				}
			}
			if (len(store.releasedIDs) == 1) != tc.wantRelease || (len(store.invalidated) == 1) != tc.invalid {
				t.Fatalf("released=%v invalidated=%v", store.releasedIDs, store.invalidated)
			}
			if store.missingFinalizationDeadline {
				t.Fatal("unbounded finalization")
			}
		})
	}
}

func TestActiveMrtTracksReadsDeviceTokenAndPropagatesRowFailures(t *testing.T) {
	sentinel := errors.New("query unavailable")
	now := time.Unix(1800000000, 0)
	for _, kind := range []string{"valid", "query failure", "scan failure", "row failure"} {
		t.Run(kind, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			query := db.ExpectQuery("SELECT r.reminder_id, COALESCE.*r.route_type = 'mrt'.*r.expires_at > \\$1").WithArgs(now)
			rows := pgxmock.NewRows([]string{"id", "token", "lead"})
			switch kind {
			case "query failure":
				query.WillReturnError(sentinel)
			case "scan failure":
				query.WillReturnRows(rows.AddRow("r1", "token", "bad"))
			case "row failure":
				query.WillReturnRows(rows.AddRow("r1", "token", 2).RowError(0, sentinel))
			default:
				query.WillReturnRows(rows.AddRow("r1", "token", 2).AddRow("r2", "", 0))
			}
			got, err := (Store{db: db}).ActiveMrtTracks(context.Background(), now)
			if kind == "valid" {
				if err != nil || len(got) != 2 || got[0].ID != "r1" || got[0].Token != "token" || got[0].LeadStops != 2 || got[1].Token != "" {
					t.Fatalf("rows=%v %v", got, err)
				}
			} else if err == nil {
				t.Fatal("storage failure dropped")
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
