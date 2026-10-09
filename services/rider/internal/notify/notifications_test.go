package notify

import (
	"context"
	"errors"
	"testing"
	"time"

	"firebase.google.com/go/v4/messaging"
)

type fakeNotificationStore struct {
	tokens                                                  []deviceToken
	reminders                                               []arrivalReminder
	matches                                                 []arrivalMatch
	batchCalls                                              int
	batchErr                                                error
	due                                                     []arrivalReminder
	claimed                                                 map[string]bool
	finalized                                               map[string]bool
	claimIDs                                                []string
	firedIDs                                                []string
	releasedIDs                                             []string
	releaseErr                                              error
	releaseChanged                                          *bool
	invalidated                                             []string
	rejectCanceledTransitions                               bool
	finalizationDeadlines                                   []time.Duration
	missingFinalizationDeadline                             bool
	invalidateErr                                           error
	claimErr                                                error
	claimErrIDs                                             map[string]bool
	dueErr                                                  error
	wantRouteType, wantRouteKey, wantStopKey, wantDirection string
}

func (s *fakeNotificationStore) activeRemindersForArrivals(_ context.Context, events []ArrivalEvent, _ time.Time) ([]arrivalMatch, error) {
	s.batchCalls++
	if s.matches != nil || s.batchErr != nil {
		return s.matches, s.batchErr
	}
	var matches []arrivalMatch
	for _, event := range events {
		if event.RouteType != s.wantRouteType || event.RouteKey != s.wantRouteKey || event.StopKey != s.wantStopKey || event.Direction != s.wantDirection {
			continue
		}
		for _, reminder := range s.reminders {
			if reminder.routeType == "" {
				reminder.routeType = event.RouteType
			}
			if reminder.routeKey == "" {
				reminder.routeKey = event.RouteKey
			}
			if reminder.stopKey == "" {
				reminder.stopKey = event.StopKey
			}
			if reminder.direction == "" {
				reminder.direction = event.Direction
			}
			matches = append(matches, arrivalMatch{reminder: reminder, arrival: event})
		}
	}
	return matches, nil
}

func (s *fakeNotificationStore) dueScheduledReminders(context.Context, time.Time) ([]arrivalReminder, error) {
	if s.dueErr != nil {
		return nil, s.dueErr
	}
	return s.due, nil
}

func (s *fakeNotificationStore) subscribedTokens(_ context.Context, routeType, routeKey string) ([]deviceToken, error) {
	if routeType != s.wantRouteType || routeKey != s.wantRouteKey {
		return nil, nil
	}
	return s.tokens, nil
}
func (s *fakeNotificationStore) claim(ctx context.Context, id string, _ time.Time) (bool, error) {
	s.claimIDs = append(s.claimIDs, id)
	if s.rejectCanceledTransitions && ctx.Err() != nil {
		return false, ctx.Err()
	}
	if s.claimErr != nil && (s.claimErrIDs == nil || s.claimErrIDs[id]) {
		return false, s.claimErr
	}
	if s.claimed[id] || s.finalized[id] {
		return false, nil
	}
	s.claimed[id] = true
	return true, nil
}
func (s *fakeNotificationStore) recordFinalizationDeadline(ctx context.Context) {
	deadline, ok := ctx.Deadline()
	if !ok {
		s.missingFinalizationDeadline = true
		return
	}
	s.finalizationDeadlines = append(s.finalizationDeadlines, time.Until(deadline))
}
func (s *fakeNotificationStore) release(ctx context.Context, id string) (bool, error) {
	s.releasedIDs = append(s.releasedIDs, id)
	s.recordFinalizationDeadline(ctx)
	if s.rejectCanceledTransitions && ctx.Err() != nil {
		return false, ctx.Err()
	}
	if s.releaseErr != nil {
		return false, s.releaseErr
	}
	changed := true
	if s.releaseChanged != nil {
		changed = *s.releaseChanged
	}
	if changed {
		s.claimed[id] = false
	}
	return changed, nil
}
func (s *fakeNotificationStore) fired(ctx context.Context, id string, _ time.Time) (bool, error) {
	s.recordFinalizationDeadline(ctx)
	if s.rejectCanceledTransitions && ctx.Err() != nil {
		return false, ctx.Err()
	}
	s.firedIDs = append(s.firedIDs, id)
	s.claimed[id] = false
	if s.finalized == nil {
		s.finalized = make(map[string]bool)
	}
	s.finalized[id] = true
	return true, nil
}
func (s *fakeNotificationStore) invalidate(ctx context.Context, token string) error {
	s.recordFinalizationDeadline(ctx)
	if s.rejectCanceledTransitions && ctx.Err() != nil {
		return ctx.Err()
	}
	s.invalidated = append(s.invalidated, token)
	return s.invalidateErr
}

type fakeFCM struct {
	messages []*messaging.Message
	err      error
	errs     map[string]error
	send     func(context.Context, *messaging.Message) error
}

func (f *fakeFCM) Send(ctx context.Context, m *messaging.Message) error {
	f.messages = append(f.messages, m)
	if f.send != nil {
		return f.send(ctx, m)
	}
	if err, ok := f.errs[m.Token]; ok {
		return err
	}
	return f.err
}

func mustDispatchArrival(t *testing.T, d *Dispatcher, event ArrivalEvent) {
	t.Helper()
	if err := d.Arrivals(context.Background(), []ArrivalEvent{event}); err != nil {
		t.Fatalf("Arrivals() error = %v", err)
	}
}

func TestFirebaseDisabledInDev(t *testing.T) {
	t.Setenv("FIREBASE_ENABLED", "true")
	t.Setenv("APP_ENV", "dev")
	sender, err := NewFirebaseSender(context.Background())
	if err != nil || sender != nil {
		t.Fatalf("sender=%v err=%v", sender, err)
	}
}

func TestRouteAlertMatchingAndDedupe(t *testing.T) {
	store := &fakeNotificationStore{tokens: []deviceToken{{"a"}, {"a"}, {"b"}}, claimed: map[string]bool{}, wantRouteType: "bus", wantRouteKey: "R1"}
	sender := &fakeFCM{}
	d := NewDispatcher(store, sender)
	d.RouteAlert(context.Background(), "bus", "R1", "延誤")
	if len(sender.messages) != 2 {
		t.Fatalf("sent=%d", len(sender.messages))
	}
	for _, m := range sender.messages {
		if m.Data["route_key"] != "R1" || m.Data["kind"] != "route_alert" || m.Data["title"] == "" || m.Data["body"] == "" {
			t.Fatalf("data=%v", m.Data)
		}
	}
}

func TestArrivalThresholdClaimAndNoDuplicate(t *testing.T) {
	store := &fakeNotificationStore{claimed: map[string]bool{}, reminders: []arrivalReminder{{id: "r1", token: "t", routeType: "bus", routeKey: "R", stopKey: "S", direction: "0", leadMinutes: 5}}, wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0"}
	sender := &fakeFCM{}
	d := NewDispatcher(store, sender)
	mustDispatchArrival(t, d, ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 301})
	if len(sender.messages) != 0 {
		t.Fatal("sent above threshold")
	}
	mustDispatchArrival(t, d, ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 300})
	mustDispatchArrival(t, d, ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 100})
	if len(sender.messages) != 1 || len(store.firedIDs) != 1 {
		t.Fatalf("sent=%d fired=%v", len(sender.messages), store.firedIDs)
	}
	m := sender.messages[0]
	if m.Data["kind"] != "arrival_reminder" || m.Notification.Title != "即將到站" || m.Android == nil || m.APNS == nil {
		t.Fatalf("message=%+v", m)
	}
}

func TestArrivalsMatchesRemindersByCompositeIdentity(t *testing.T) {
	events := []ArrivalEvent{
		{RouteType: "bus", RouteKey: "R", StopKey: "S1", Direction: "0", ETASeconds: 60, ArrivingPlate: "BUS-1"},
		{RouteType: "bus", RouteKey: "R", StopKey: "S2", Direction: "1", ETASeconds: 240, ArrivingPlate: "BUS-2"},
	}
	store := &fakeNotificationStore{
		claimed: map[string]bool{},
		matches: []arrivalMatch{
			{reminder: arrivalReminder{id: "r1", token: "token-1", routeType: "bus", routeKey: "R", stopKey: "S1", direction: "0", leadMinutes: 1}, arrival: events[0]},
			{reminder: arrivalReminder{id: "r2", token: "token-2", routeType: "bus", routeKey: "R", stopKey: "S2", direction: "1", leadMinutes: 5}, arrival: events[1]},
		},
	}
	sender := &fakeFCM{}
	if err := NewDispatcher(store, sender).Arrivals(context.Background(), events); err != nil {
		t.Fatalf("Arrivals() error = %v", err)
	}
	if store.batchCalls != 1 || len(sender.messages) != 2 || len(store.firedIDs) != 2 {
		t.Fatalf("batch calls = %d, sent = %d, fired = %v", store.batchCalls, len(sender.messages), store.firedIDs)
	}
	if sender.messages[0].Token != "token-1" || sender.messages[0].Data["body"] != "預計 1 分鐘後到站" ||
		sender.messages[1].Token != "token-2" || sender.messages[1].Data["body"] != "預計 4 分鐘後到站" {
		t.Fatalf("messages were cross-matched: first=%+v second=%+v", sender.messages[0], sender.messages[1])
	}
}

func TestArrivalPinnedFiresOnlyForMatchingPlate(t *testing.T) {
	store := &fakeNotificationStore{claimed: map[string]bool{}, reminders: []arrivalReminder{{id: "r1", token: "t", routeType: "bus", routeKey: "R", stopKey: "S", direction: "0", leadMinutes: 5, plate: "KKA-1288"}}, wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0"}
	sender := &fakeFCM{}
	d := NewDispatcher(store, sender)

	// Within lead, but a different bus is arriving: no push.
	mustDispatchArrival(t, d, ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60, ArrivingPlate: "OTHER-9999"})
	if len(sender.messages) != 0 {
		t.Fatalf("fired for wrong plate: sent=%d", len(sender.messages))
	}
	// The pinned plate arrives: push.
	mustDispatchArrival(t, d, ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60, ArrivingPlate: "KKA-1288"})
	if len(sender.messages) != 1 || len(store.firedIDs) != 1 {
		t.Fatalf("pinned plate did not fire: sent=%d fired=%v", len(sender.messages), store.firedIDs)
	}
}

func TestArrivalPinnedDoesNotFireWhenArrivingPlateEmpty(t *testing.T) {
	store := &fakeNotificationStore{claimed: map[string]bool{}, reminders: []arrivalReminder{{id: "r1", token: "t", routeType: "bus", routeKey: "R", stopKey: "S", direction: "0", leadMinutes: 5, plate: "KKA-1288"}}, wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0"}
	sender := &fakeFCM{}
	mustDispatchArrival(t, NewDispatcher(store, sender), ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60})
	if len(sender.messages) != 0 {
		t.Fatalf("pinned reminder fired on empty arriving plate: sent=%d", len(sender.messages))
	}
}

func TestArrivalUnpinnedIgnoresArrivingPlate(t *testing.T) {
	store := &fakeNotificationStore{claimed: map[string]bool{}, reminders: []arrivalReminder{{id: "r1", token: "t", routeType: "bus", routeKey: "R", stopKey: "S", direction: "0", leadMinutes: 5}}, wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0"}
	sender := &fakeFCM{}
	mustDispatchArrival(t, NewDispatcher(store, sender), ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60, ArrivingPlate: "ANY-0000"})
	if len(sender.messages) != 1 {
		t.Fatalf("legacy reminder must fire regardless of plate: sent=%d", len(sender.messages))
	}
}

// TestNormalizeAlertsCapturesDepartment verifies the publishing department
// TDX names on the alert is carried through as-is, so the app can label a row
// by its real publisher rather than a hardcoded city name.

// A payload that cannot be understood must not become an empty snapshot: the
// snapshot is what seeds every new subscriber, so writing nothing over the last
// good one would blank the alert list for everyone.

// A valid but empty payload is TDX saying the disruption cleared, and must
// be written through so the list actually empties.

// Metro lines are keys now: a 收藏 of a station on BL resolves to BL, so a
// BL disruption must not blast every metro subscriber.

// A metro alert that names no line stays system-wide.

// A suspension is graded red whether TDX publishes Status as a string or a
// number; everything else is advisory.

// TestAlertTimeParsesEveryTDXLayout covers the three UpdateTime/PublishTime
// shapes TDX publishes across feeds, plus the fallback to 0 when neither field
// parses. All three timestamps name the same instant, so they must agree.

// 2026-07-26T09:30:00+08:00

// TestNormalizeAlertsFoldsRepeatedBodies covers the TDX Bus/Alert shape where
// the affected routes live in Scope.SubRoutes / Scope.Routes rather than at the
// top level: one disruption collects every route it scopes into one alert.

// TestAlertItemsUnwrapEnvelope covers the metro/TRA authority envelope, which
// carries several alerts per message instead of a bare array.

// TestRouteAlertCoversEveryTransitType pins that disruption pushes reach all
// four subscribable types, and that an unknown type stays a no-op.
func TestRouteAlertCoversEveryTransitType(t *testing.T) {
	for _, routeType := range []string{"bus", "mrt", "tra", "thsr"} {
		store := &fakeNotificationStore{
			tokens:        []deviceToken{{"token"}},
			claimed:       map[string]bool{},
			wantRouteType: routeType,
			wantRouteKey:  "123",
		}
		sender := &fakeFCM{}
		NewDispatcher(store, sender).RouteAlert(context.Background(), routeType, "123", "延誤")
		if len(sender.messages) != 1 {
			t.Fatalf("%s route alert sent=%d, want 1", routeType, len(sender.messages))
		}
	}
	store := &fakeNotificationStore{tokens: []deviceToken{{"token"}}, claimed: map[string]bool{}}
	sender := &fakeFCM{}
	NewDispatcher(store, sender).RouteAlert(context.Background(), "ferry", "123", "延誤")
	if len(sender.messages) != 0 {
		t.Fatalf("unknown transit type sent=%d", len(sender.messages))
	}
}

// TestLineWideAlertTitlesBroaderScope pins the empty-key path: a line-wide
// disruption still dispatches (to every subscriber of that type) and is
// labelled 營運通阻 rather than naming one route.
func TestLineWideAlertTitlesBroaderScope(t *testing.T) {
	store := &fakeNotificationStore{
		tokens:        []deviceToken{{"token"}},
		claimed:       map[string]bool{},
		wantRouteType: "thsr",
		wantRouteKey:  "",
	}
	sender := &fakeFCM{}
	NewDispatcher(store, sender).RouteAlert(context.Background(), "thsr", "", "全線延誤")
	if len(sender.messages) != 1 || sender.messages[0].Notification.Title != "營運通阻" {
		t.Fatalf("line-wide alert = %+v", sender.messages)
	}
}

func TestArrivalFiresForNonBusTypes(t *testing.T) {
	// Arrival reminders are transport-agnostic: metro/TRA/THSR fire the same way
	// as bus once their ETA source computes a usable etaSeconds.
	for _, routeType := range []string{"mrt", "tra", "thsr"} {
		t.Run(routeType, func(t *testing.T) {
			store := &fakeNotificationStore{
				claimed:       map[string]bool{},
				reminders:     []arrivalReminder{{id: "r1", token: "t", routeType: routeType, routeKey: "R", stopKey: "S", direction: "0", leadMinutes: 5}},
				wantRouteType: routeType,
				wantRouteKey:  "R",
				wantStopKey:   "S",
				wantDirection: "0",
			}
			sender := &fakeFCM{}
			d := NewDispatcher(store, sender)
			mustDispatchArrival(t, d, ArrivalEvent{RouteType: routeType, RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60})
			if len(sender.messages) != 1 || len(store.firedIDs) != 1 {
				t.Fatalf("sent=%d fired=%v", len(sender.messages), store.firedIDs)
			}
			if store.firedIDs[0] != "r1" || sender.messages[0].Data["route_type"] != routeType {
				t.Fatalf("message=%+v fired=%v", sender.messages[0].Data, store.firedIDs)
			}
		})
	}
}

func TestFireScheduledClaimsSendsAndFires(t *testing.T) {
	store := &fakeNotificationStore{
		claimed: map[string]bool{},
		due:     []arrivalReminder{{id: "r1", token: "t", routeType: "tra", routeKey: "1120", stopKey: "南港", direction: "0", leadMinutes: 3}},
	}
	sender := &fakeFCM{}
	d := NewDispatcher(store, sender)
	if err := d.FireScheduled(context.Background()); err != nil {
		t.Fatalf("FireScheduled() error = %v", err)
	}
	if len(sender.messages) != 1 || len(store.firedIDs) != 1 {
		t.Fatalf("sent=%d fired=%v", len(sender.messages), store.firedIDs)
	}
	m := sender.messages[0]
	if m.Data["kind"] != "arrival_reminder" || m.Data["route_type"] != "tra" || m.Notification.Title != "即將到站" {
		t.Fatalf("message=%+v", m.Data)
	}
	// A later tick that still sees the (unremoved) reminder must not resend it:
	// the claim guard prevents duplicate pushes across ticks.
	if err := d.FireScheduled(context.Background()); err != nil {
		t.Fatalf("FireScheduled() second call error = %v", err)
	}
	if len(sender.messages) != 1 {
		t.Fatalf("resent claimed reminder: sent=%d", len(sender.messages))
	}
}

func TestFireScheduledSurfacesClaimError(t *testing.T) {
	claimErr := errors.New("claim db unavailable")
	store := &fakeNotificationStore{
		claimed:  map[string]bool{},
		due:      []arrivalReminder{{id: "r1", token: "t", routeType: "tra", routeKey: "1120", stopKey: "南港", direction: "0", leadMinutes: 3}},
		claimErr: claimErr,
	}
	sender := &fakeFCM{}
	d := NewDispatcher(store, sender)
	err := d.FireScheduled(context.Background())
	if !errors.Is(err, claimErr) {
		t.Fatalf("FireScheduled() error = %v, want wrapped %v", err, claimErr)
	}
	if len(sender.messages) != 0 {
		t.Fatalf("sent reminder despite claim error: sent=%d", len(sender.messages))
	}
}

func TestFireScheduledSurfacesDueQueryError(t *testing.T) {
	dueErr := errors.New("query timeout")
	store := &fakeNotificationStore{claimed: map[string]bool{}, dueErr: dueErr}
	d := NewDispatcher(store, &fakeFCM{})
	err := d.FireScheduled(context.Background())
	if !errors.Is(err, dueErr) {
		t.Fatalf("FireScheduled() error = %v, want wrapped %v", err, dueErr)
	}
}

func TestFireScheduledReleaseFailureSurfacedAndReminderStaysStuck(t *testing.T) {
	sendErr := errors.New("temporary FCM outage")
	releaseErr := errors.New("release db unavailable")
	store := &fakeNotificationStore{
		claimed:    map[string]bool{},
		due:        []arrivalReminder{{id: "r1", token: "t", routeType: "tra", routeKey: "1120", stopKey: "南港", direction: "0", leadMinutes: 3}},
		releaseErr: releaseErr,
	}
	sender := &fakeFCM{err: sendErr}
	d := NewDispatcher(store, sender)
	err := d.FireScheduled(context.Background())
	if !errors.Is(err, releaseErr) {
		t.Fatalf("FireScheduled() error = %v, want wrapped %v", err, releaseErr)
	}
	if !errors.Is(err, sendErr) {
		t.Fatalf("FireScheduled() error = %v, want also wrapped %v", err, sendErr)
	}
	if len(store.releasedIDs) != 1 || store.releasedIDs[0] != "r1" {
		t.Fatalf("release attempts = %v, want [r1]", store.releasedIDs)
	}
	// Release failed, so the reminder must remain claimed (stuck in
	// 'sending') rather than silently freed for the next tick to skip.
	if !store.claimed["r1"] {
		t.Fatal("reminder was freed despite a failed release — would resend or silently drop")
	}
}

func TestFireScheduledTransientSendFailureReleasesClaim(t *testing.T) {
	sendErr := errors.New("temporary FCM outage")
	store := &fakeNotificationStore{
		claimed: map[string]bool{},
		due:     []arrivalReminder{{id: "r1", token: "t", routeType: "tra", routeKey: "1120", stopKey: "南港", direction: "0", leadMinutes: 3}},
	}
	sender := &fakeFCM{err: sendErr}
	d := NewDispatcher(store, sender)
	err := d.FireScheduled(context.Background())
	if !errors.Is(err, sendErr) {
		t.Fatalf("FireScheduled() error = %v, want wrapped %v", err, sendErr)
	}
	if len(store.releasedIDs) != 1 || store.releasedIDs[0] != "r1" {
		t.Fatalf("released reminders = %v, want [r1]", store.releasedIDs)
	}
	if store.claimed["r1"] {
		t.Fatal("reminder stayed claimed after a successful release — next tick can't retry it")
	}
}

// TDX republishes an ongoing disruption with a fresh UpdateTime and
// sometimes a fresh AlertID while the text never changes. Identity is the
// body, so a republish must not re-notify.

// Text that actually changed is a new alert and must reach the rider.

// The claim window has to outlast the disruption it dedupes, or a multi-day
// closure re-notifies every time it lapses.

func TestArrivalCancelledBeforeClaimDoesNotSend(t *testing.T) {
	store := &fakeNotificationStore{claimed: map[string]bool{"r1": true}, reminders: []arrivalReminder{{id: "r1", token: "t", leadMinutes: 5}}, wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0"}
	sender := &fakeFCM{}
	mustDispatchArrival(t, NewDispatcher(store, sender), ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 1})
	if len(sender.messages) != 0 {
		t.Fatal("sent cancelled reminder")
	}
}

func TestArrivalTransientSendFailureReleasesClaim(t *testing.T) {
	sendErr := errors.New("temporary FCM outage")
	store := &fakeNotificationStore{
		claimed:       map[string]bool{},
		reminders:     []arrivalReminder{{id: "r1", token: "token", leadMinutes: 5}},
		wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0",
	}
	sender := &fakeFCM{err: sendErr}
	if err := NewDispatcher(store, sender).Arrivals(context.Background(), []ArrivalEvent{{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60}}); !errors.Is(err, sendErr) {
		t.Fatalf("Arrivals() error = %v, want %v", err, sendErr)
	}
	if len(store.releasedIDs) != 1 || store.releasedIDs[0] != "r1" {
		t.Fatalf("released reminders = %v, want [r1]", store.releasedIDs)
	}
}

func TestArrivalsReleasesWithDetachedContextAndStopsAfterParentCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	first := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S1", Direction: "0", ETASeconds: 60}
	second := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S2", Direction: "0", ETASeconds: 120}
	store := &fakeNotificationStore{
		claimed:                   map[string]bool{},
		rejectCanceledTransitions: true,
		matches: []arrivalMatch{
			{reminder: arrivalReminder{id: "r1", token: "first", routeType: "bus", routeKey: "R", stopKey: "S1", direction: "0", leadMinutes: 5}, arrival: first},
			{reminder: arrivalReminder{id: "r2", token: "second", routeType: "bus", routeKey: "R", stopKey: "S2", direction: "0", leadMinutes: 5}, arrival: second},
		},
	}
	sender := &fakeFCM{send: func(ctx context.Context, _ *messaging.Message) error {
		cancel()
		return ctx.Err()
	}}

	err := NewDispatcher(store, sender).Arrivals(ctx, []ArrivalEvent{first, second})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Arrivals() error = %v, want context canceled", err)
	}
	if store.claimed["r1"] || len(store.releasedIDs) != 1 || store.releasedIDs[0] != "r1" {
		t.Fatalf("first reminder remained claimed: claimed=%v released=%v", store.claimed, store.releasedIDs)
	}
	if len(store.claimIDs) != 1 || store.claimIDs[0] != "r1" || len(sender.messages) != 1 {
		t.Fatalf("processed new reminder after cancellation: claims=%v sends=%d", store.claimIDs, len(sender.messages))
	}
	if store.missingFinalizationDeadline || len(store.finalizationDeadlines) != 1 || store.finalizationDeadlines[0] <= 0 || store.finalizationDeadlines[0] > ArrivalFinalizationTimeout {
		t.Fatalf("release finalization deadlines = %v missing=%v, want one bounded deadline", store.finalizationDeadlines, store.missingFinalizationDeadline)
	}
}

func TestArrivalsStartsFinalizationDeadlineAfterSendReturns(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	event := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60}
	store := &fakeNotificationStore{
		claimed: map[string]bool{}, rejectCanceledTransitions: true,
		matches: []arrivalMatch{{
			reminder: arrivalReminder{id: "r1", token: "token", routeType: "bus", routeKey: "R", stopKey: "S", direction: "0", leadMinutes: 5},
			arrival:  event,
		}},
	}
	timeout := 5 * time.Millisecond
	sender := &fakeFCM{send: func(ctx context.Context, _ *messaging.Message) error {
		time.Sleep(2 * timeout)
		cancel()
		return ctx.Err()
	}}
	dispatcher := NewDispatcher(store, sender)
	dispatcher.finalizationTimeout = timeout

	err := dispatcher.Arrivals(ctx, []ArrivalEvent{event})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Arrivals() error = %v, want context canceled", err)
	}
	if store.claimed["r1"] || len(store.releasedIDs) != 1 {
		t.Fatalf("reminder remained claimed after slow send: claimed=%v released=%v", store.claimed, store.releasedIDs)
	}
	if store.missingFinalizationDeadline || len(store.finalizationDeadlines) != 1 || store.finalizationDeadlines[0] <= 0 {
		t.Fatalf("release finalization deadlines = %v missing=%v, want deadline starting after send", store.finalizationDeadlines, store.missingFinalizationDeadline)
	}
}

func TestArrivalsMarksFiredWithDetachedContextAfterParentCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	first := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S1", Direction: "0", ETASeconds: 60}
	second := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S2", Direction: "0", ETASeconds: 120}
	store := &fakeNotificationStore{
		claimed:                   map[string]bool{},
		rejectCanceledTransitions: true,
		matches: []arrivalMatch{
			{reminder: arrivalReminder{id: "r1", token: "first", routeType: "bus", routeKey: "R", stopKey: "S1", direction: "0", leadMinutes: 5}, arrival: first},
			{reminder: arrivalReminder{id: "r2", token: "second", routeType: "bus", routeKey: "R", stopKey: "S2", direction: "0", leadMinutes: 5}, arrival: second},
		},
	}
	sender := &fakeFCM{send: func(context.Context, *messaging.Message) error {
		cancel()
		return nil
	}}

	err := NewDispatcher(store, sender).Arrivals(ctx, []ArrivalEvent{first, second})
	if !errors.Is(err, context.Canceled) || len(store.firedIDs) != 1 || store.firedIDs[0] != "r1" || store.claimed["r1"] {
		t.Fatalf("error=%v fired=%v claimed=%v, want canceled with r1 finalized", err, store.firedIDs, store.claimed)
	}
	if len(store.claimIDs) != 1 || len(sender.messages) != 1 {
		t.Fatalf("processed new reminder after cancellation: claims=%v sends=%d", store.claimIDs, len(sender.messages))
	}
}

func TestArrivalsReturnsTransientSendAndReleaseFailures(t *testing.T) {
	sendErr := errors.New("temporary FCM outage")
	releaseErr := errors.New("release update failed")
	event := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 60}
	store := &fakeNotificationStore{
		claimed:    map[string]bool{},
		releaseErr: releaseErr,
		matches: []arrivalMatch{{
			reminder: arrivalReminder{id: "r1", token: "token", routeType: "bus", routeKey: "R", stopKey: "S", direction: "0", leadMinutes: 5},
			arrival:  event,
		}},
	}
	err := NewDispatcher(store, &fakeFCM{err: sendErr}).Arrivals(context.Background(), []ArrivalEvent{event})
	if !errors.Is(err, sendErr) || !errors.Is(err, releaseErr) {
		t.Fatalf("Arrivals() error = %v, want send %v and release %v", err, sendErr, releaseErr)
	}
	if len(store.releasedIDs) != 1 || store.releasedIDs[0] != "r1" {
		t.Fatalf("released reminders = %v, want [r1]", store.releasedIDs)
	}
}

func TestArrivalsContinuesBatchAfterTransientSendFailure(t *testing.T) {
	sendErr := errors.New("temporary FCM outage")
	first := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S1", Direction: "0", ETASeconds: 60}
	second := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S2", Direction: "0", ETASeconds: 120}
	store := &fakeNotificationStore{
		claimed: map[string]bool{},
		matches: []arrivalMatch{
			{reminder: arrivalReminder{id: "r1", token: "bad", routeType: "bus", routeKey: "R", stopKey: "S1", direction: "0", leadMinutes: 5}, arrival: first},
			{reminder: arrivalReminder{id: "r2", token: "good", routeType: "bus", routeKey: "R", stopKey: "S2", direction: "0", leadMinutes: 5}, arrival: second},
		},
	}
	sender := &fakeFCM{errs: map[string]error{"bad": sendErr}}
	err := NewDispatcher(store, sender).Arrivals(context.Background(), []ArrivalEvent{first, second})
	if !errors.Is(err, sendErr) {
		t.Fatalf("Arrivals() error = %v, want %v", err, sendErr)
	}
	if len(store.releasedIDs) != 1 || store.releasedIDs[0] != "r1" || len(store.firedIDs) != 1 || store.firedIDs[0] != "r2" {
		t.Fatalf("released = %v, fired = %v; later reminder was not completed", store.releasedIDs, store.firedIDs)
	}
}

func TestInvalidTokenCleanupAndAtMostOnce(t *testing.T) {
	sendErr := errors.New("invalid token")
	store := &fakeNotificationStore{claimed: map[string]bool{}, reminders: []arrivalReminder{{id: "r1", token: "bad", leadMinutes: 5}}, wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0"}
	sender := &fakeFCM{err: sendErr}
	d := NewDispatcher(store, sender)
	d.isInvalidFCMToken = func(err error) bool { return errors.Is(err, sendErr) }
	err := d.Arrivals(context.Background(), []ArrivalEvent{{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 1}})
	if !errors.Is(err, sendErr) {
		t.Fatalf("Arrivals() error = %v, want invalid-token send error %v", err, sendErr)
	}
	if len(store.invalidated) != 1 || len(store.releasedIDs) != 1 || len(store.firedIDs) != 0 || store.claimed["r1"] {
		t.Fatalf("invalidated=%v released=%v fired=%v claimed=%v", store.invalidated, store.releasedIDs, store.firedIDs, store.claimed)
	}
}

func TestInvalidTokenFinalizesWithDetachedContextAfterParentCancel(t *testing.T) {
	sendErr := errors.New("invalid token")
	ctx, cancel := context.WithCancel(context.Background())
	first := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S1", Direction: "0", ETASeconds: 60}
	second := ArrivalEvent{RouteType: "bus", RouteKey: "R", StopKey: "S2", Direction: "0", ETASeconds: 120}
	store := &fakeNotificationStore{
		claimed: map[string]bool{}, rejectCanceledTransitions: true,
		matches: []arrivalMatch{
			{reminder: arrivalReminder{id: "r1", token: "bad", routeType: "bus", routeKey: "R", stopKey: "S1", direction: "0", leadMinutes: 5}, arrival: first},
			{reminder: arrivalReminder{id: "r2", token: "good", routeType: "bus", routeKey: "R", stopKey: "S2", direction: "0", leadMinutes: 5}, arrival: second},
		},
	}
	sender := &fakeFCM{send: func(context.Context, *messaging.Message) error {
		cancel()
		return sendErr
	}}

	d := NewDispatcher(store, sender)
	d.isInvalidFCMToken = func(err error) bool { return errors.Is(err, sendErr) }
	err := d.Arrivals(ctx, []ArrivalEvent{first, second})
	if !errors.Is(err, sendErr) || !errors.Is(err, context.Canceled) {
		t.Fatalf("Arrivals() error = %v, want invalid token and context canceled", err)
	}
	if len(store.invalidated) != 1 || len(store.releasedIDs) != 1 || store.claimed["r1"] {
		t.Fatalf("invalidated=%v released=%v claimed=%v", store.invalidated, store.releasedIDs, store.claimed)
	}
	if len(store.claimIDs) != 1 || len(sender.messages) != 1 {
		t.Fatalf("processed new reminder after cancellation: claims=%v sends=%d", store.claimIDs, len(sender.messages))
	}
	if store.missingFinalizationDeadline || len(store.finalizationDeadlines) != 2 {
		t.Fatalf("invalid-token finalization deadlines = %v missing=%v", store.finalizationDeadlines, store.missingFinalizationDeadline)
	}
	for _, remaining := range store.finalizationDeadlines {
		if remaining <= 0 || remaining > ArrivalFinalizationTimeout {
			t.Fatalf("invalid-token finalization deadline remaining = %v, want (0, %v]", remaining, ArrivalFinalizationTimeout)
		}
	}
}

func TestInvalidTokenReturnsInvalidateAndReleaseFailures(t *testing.T) {
	sendErr := errors.New("invalid token")
	invalidateErr := errors.New("invalidate failed")
	releaseErr := errors.New("release failed")
	store := &fakeNotificationStore{
		claimed: map[string]bool{}, invalidateErr: invalidateErr, releaseErr: releaseErr,
		reminders:     []arrivalReminder{{id: "r1", token: "bad", leadMinutes: 5}},
		wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0",
	}
	d := NewDispatcher(store, &fakeFCM{err: sendErr})
	d.isInvalidFCMToken = func(err error) bool { return errors.Is(err, sendErr) }
	err := d.Arrivals(context.Background(), []ArrivalEvent{{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 1}})
	if !errors.Is(err, sendErr) || !errors.Is(err, invalidateErr) || !errors.Is(err, releaseErr) {
		t.Fatalf("Arrivals() error = %v, want send/invalidate/release failures", err)
	}
}

func TestInvalidTokenReturnsZeroRowReleaseFailure(t *testing.T) {
	sendErr := errors.New("invalid token")
	changed := false
	store := &fakeNotificationStore{
		claimed: map[string]bool{}, releaseChanged: &changed,
		reminders:     []arrivalReminder{{id: "r1", token: "bad", leadMinutes: 5}},
		wantRouteType: "bus", wantRouteKey: "R", wantStopKey: "S", wantDirection: "0",
	}
	d := NewDispatcher(store, &fakeFCM{err: sendErr})
	d.isInvalidFCMToken = func(err error) bool { return errors.Is(err, sendErr) }
	err := d.Arrivals(context.Background(), []ArrivalEvent{{RouteType: "bus", RouteKey: "R", StopKey: "S", Direction: "0", ETASeconds: 1}})
	if !errors.Is(err, sendErr) || !errMentions(err, "release arrival reminder r1 changed no rows") {
		t.Fatalf("Arrivals() error = %v, want send and zero-row release failures", err)
	}
}

func TestFireMrtVibrateSendsDataOnlyAndFiresOnce(t *testing.T) {
	store := &fakeNotificationStore{claimed: map[string]bool{}}
	sender := &fakeFCM{}
	d := NewDispatcher(store, sender)

	fired, err := d.FireMrtVibrate(context.Background(), MrtVibrateEvent{ReminderID: "r1", Token: "tok", TrackID: "r1", AlightEvent: "alight"})
	if err != nil || !fired {
		t.Fatalf("FireMrtVibrate() = %v, %v", fired, err)
	}
	if len(sender.messages) != 1 {
		t.Fatalf("sent=%d want 1", len(sender.messages))
	}
	msg := sender.messages[0]
	if msg.Notification != nil {
		t.Error("vibrate message must carry no notification payload")
	}
	if msg.Data["type"] != "alight_vibrate" || msg.Data["track_id"] != "r1" || msg.Data["event"] != "alight" {
		t.Errorf("data = %v", msg.Data)
	}
	if msg.Android == nil || msg.Android.Priority != "high" {
		t.Error("vibrate message must be android high priority")
	}
	if len(store.firedIDs) != 1 || store.firedIDs[0] != "r1" {
		t.Errorf("firedIDs = %v", store.firedIDs)
	}

	// A second attempt loses the claim (already fired) and does not re-send.
	fired, err = d.FireMrtVibrate(context.Background(), MrtVibrateEvent{ReminderID: "r1", Token: "tok", TrackID: "r1"})
	if err != nil || fired {
		t.Fatalf("second FireMrtVibrate() = %v, %v", fired, err)
	}
	if len(sender.messages) != 1 {
		t.Errorf("second attempt sent again, total=%d", len(sender.messages))
	}
}

func TestFireMrtVibrateNoTokenIsNoop(t *testing.T) {
	store := &fakeNotificationStore{claimed: map[string]bool{}}
	sender := &fakeFCM{}
	fired, err := NewDispatcher(store, sender).FireMrtVibrate(context.Background(), MrtVibrateEvent{ReminderID: "r1", Token: "", TrackID: "r1"})
	if err != nil || fired {
		t.Fatalf("FireMrtVibrate() no token = %v, %v", fired, err)
	}
	if len(sender.messages) != 0 || len(store.claimIDs) != 0 {
		t.Error("no-token vibrate must not claim or send")
	}
}
