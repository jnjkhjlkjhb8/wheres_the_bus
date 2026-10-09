package notify

import (
	"context"
	"encoding/json"
	"regexp"
	"testing"
	"time"

	"github.com/pashagolub/pgxmock/v4"
)

type arrivalEventsJSONMatcher struct {
	want []ArrivalEvent
}

func (m arrivalEventsJSONMatcher) Match(value any) bool {
	var payload []byte
	switch value := value.(type) {
	case string:
		payload = []byte(value)
	case []byte:
		payload = value
	default:
		return false
	}
	var got []ArrivalEvent
	if err := json.Unmarshal(payload, &got); err != nil || len(got) != len(m.want) {
		return false
	}
	for i := range got {
		if got[i] != m.want[i] {
			return false
		}
	}
	return true
}

func TestArrivalEventsJSONMatcherRejectsWrongPayload(t *testing.T) {
	want := []ArrivalEvent{
		{RouteType: "bus", RouteKey: "R1", StopKey: "S1", Direction: "0", ETASeconds: 60, ArrivingPlate: "BUS-1"},
		{RouteType: "bus", RouteKey: "R2", StopKey: "S2", Direction: "1", ETASeconds: 120, ArrivingPlate: "BUS-2"},
	}
	wrong, err := json.Marshal([]ArrivalEvent{want[1], want[0]})
	if err != nil {
		t.Fatal(err)
	}
	if (arrivalEventsJSONMatcher{want: want}).Match(string(wrong)) {
		t.Fatal("matcher accepted arrival events in the wrong order")
	}
}

func TestNotificationStoreActiveRemindersUsesOneCompositeBatchQuery(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Unix(1_800_000_000, 0)
	events := []ArrivalEvent{
		{RouteType: "bus", RouteKey: "R", StopKey: "S1", Direction: "0", ETASeconds: 60, ArrivingPlate: "BUS-1"},
		{RouteType: "bus", RouteKey: "R", StopKey: "S2", Direction: "1", ETASeconds: 240, ArrivingPlate: "BUS-2"},
	}
	db.ExpectQuery("jsonb_to_recordset"+regexp.QuoteMeta("($1::jsonb)")+
		".*r\\.route_type=a\\.route_type AND r\\.route_key=a\\.route_key"+
		".*r\\.stop_key=a\\.stop_key AND r\\.direction=a\\.direction"+
		".*a\\.eta_seconds<=r\\.lead_minutes\\*60"+
		".*r\\.plate='' OR r\\.plate=a\\.arriving_plate"+
		".*r\\.status='pending' OR \\(r\\.status='sending' AND \\(r\\.claimed_at IS NULL OR r\\.claimed_at<=\\$3\\)\\)").
		WithArgs(arrivalEventsJSONMatcher{want: events}, now, now.Add(-ReminderClaimTimeout)).
		WillReturnRows(pgxmock.NewRows([]string{
			"reminder_id", "fcm_token", "route_type", "route_key", "stop_key", "direction", "lead_minutes", "plate", "alight_event",
			"arrival_route_type", "arrival_route_key", "arrival_stop_key", "arrival_direction", "eta_seconds", "arriving_plate",
		}).AddRow("r2", "token-2", "bus", "R", "S2", "1", 5, "BUS-2", "", "bus", "R", "S2", "1", int32(240), "BUS-2"))

	matches, err := (Store{db: db}).activeRemindersForArrivals(context.Background(), events, now)
	if err != nil {
		t.Fatalf("activeRemindersForArrivals() error = %v", err)
	}
	if len(matches) != 1 || matches[0].reminder.id != "r2" || matches[0].arrival != events[1] {
		t.Fatalf("matches = %#v, want reminder r2 matched to second composite event", matches)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestNotificationStoreFiltersRouteAndEnabledDevice(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery("FROM firebase_route_subscription.*s.route_type=\\$1 AND \\(\\$2='' OR s.route_key=\\$2\\).*d.push_enabled").WithArgs("bus", "R1").WillReturnRows(pgxmock.NewRows([]string{"fcm_token"}).AddRow("token"))
	got, err := (Store{db: db}).subscribedTokens(context.Background(), "bus", "R1")
	if err != nil || len(got) != 1 || got[0].token != "token" {
		t.Fatalf("got=%v err=%v", got, err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// _claimExecPattern matches the single-statement claim UPDATE: it must stamp
// claimed_at, stay conditional on expiry, and accept 'pending' plus timed-out
// (or pre-column NULL) 'sending' rows in one atomic predicate.
const _claimExecPattern = "UPDATE firebase_arrival_reminder SET status='sending',claimed_at=\\$2" +
	".*expires_at>\\$2" +
	".*status='pending' OR \\(status='sending' AND \\(claimed_at IS NULL OR claimed_at<=\\$3\\)\\)"

func TestNotificationStoreClaimIsAtomic(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Now()
	cutoff := now.Add(-ReminderClaimTimeout)
	db.ExpectExec(_claimExecPattern).WithArgs("r1", now, cutoff).WillReturnResult(pgxmock.NewResult("UPDATE", 1))
	claimed, err := (Store{db: db}).claim(context.Background(), "r1", now)
	if err != nil || !claimed {
		t.Fatalf("claimed=%v err=%v", claimed, err)
	}
	db.ExpectExec(_claimExecPattern).WithArgs("r1", now, cutoff).WillReturnResult(pgxmock.NewResult("UPDATE", 0))
	claimed, err = (Store{db: db}).claim(context.Background(), "r1", now)
	if err != nil || claimed {
		t.Fatalf("claimed=%v err=%v", claimed, err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestNotificationStoreClaimReclaimCutoff(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Unix(1_800_000_000, 0)
	cutoff := now.Add(-ReminderClaimTimeout)

	// Stuck sender: its claimed_at is at/before the cutoff, so the predicate
	// matches and the reclaim wins the row.
	db.ExpectExec(_claimExecPattern).WithArgs("stuck", now, cutoff).WillReturnResult(pgxmock.NewResult("UPDATE", 1))
	claimed, err := (Store{db: db}).claim(context.Background(), "stuck", now)
	if err != nil || !claimed {
		t.Fatalf("reclaim after timeout: claimed=%v err=%v", claimed, err)
	}

	// Live sender: claimed_at is newer than the cutoff, the predicate matches
	// no row, and the caller must treat the reminder as still owned.
	db.ExpectExec(_claimExecPattern).WithArgs("in-flight", now, cutoff).WillReturnResult(pgxmock.NewResult("UPDATE", 0))
	claimed, err = (Store{db: db}).claim(context.Background(), "in-flight", now)
	if err != nil || claimed {
		t.Fatalf("no reclaim before timeout: claimed=%v err=%v", claimed, err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestNotificationStoreReleaseClearsClaimedAt(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectExec("UPDATE firebase_arrival_reminder SET status='pending',claimed_at=NULL.*status='sending'").
		WithArgs("r1").WillReturnResult(pgxmock.NewResult("UPDATE", 1))
	released, err := (Store{db: db}).release(context.Background(), "r1")
	if err != nil || !released {
		t.Fatalf("released=%v err=%v", released, err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestNotificationStoreScheduledSweepIncludesTimedOutSending guards the
// end-to-end retry path: without the reclaim arm in dueScheduledReminders'
// WHERE clause, a stranded 'sending' reminder would never reach claim() at all.
func TestNotificationStoreScheduledSweepIncludesTimedOutSending(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Unix(1_800_000_000, 0)
	db.ExpectQuery("FROM firebase_arrival_reminder r"+
		".*r\\.status='pending' OR \\(r\\.status='sending' AND \\(r\\.claimed_at IS NULL OR r\\.claimed_at<=\\$2\\)\\)"+
		".*r\\.fire_at<=\\$1 AND r\\.expires_at>\\$1").
		WithArgs(now, now.Add(-ReminderClaimTimeout)).
		WillReturnRows(pgxmock.NewRows([]string{"reminder_id", "fcm_token", "route_type", "route_key", "stop_key", "direction", "lead_minutes", "alight_event"}).
			AddRow("r1", "token", "tra", "R", "S", "0", 5, ""))
	out, err := (Store{db: db}).dueScheduledReminders(context.Background(), now)
	if err != nil || len(out) != 1 || out[0].id != "r1" {
		t.Fatalf("out=%v err=%v", out, err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestNotificationStoreFiredAndInvalidToken(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Now()
	db.ExpectExec("UPDATE firebase_arrival_reminder SET status='fired'.*status='sending'").WithArgs("r1", now).WillReturnResult(pgxmock.NewResult("UPDATE", 1))
	fired, err := (Store{db: db}).fired(context.Background(), "r1", now)
	if err != nil || !fired {
		t.Fatalf("fired=%v err=%v", fired, err)
	}
	db.ExpectExec("UPDATE firebase_device SET fcm_token='',push_enabled=FALSE.*fcm_token=\\$1").WithArgs("bad").WillReturnResult(pgxmock.NewResult("UPDATE", 1))
	if err := (Store{db: db}).invalidate(context.Background(), "bad"); err != nil {
		t.Fatal(err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
