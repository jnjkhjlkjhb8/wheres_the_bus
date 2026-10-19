package notify

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"firebase.google.com/go/v4/messaging"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"go.uber.org/zap"
)

// ArrivalEvent is one live vehicle arrival considered for reminder dispatch.
// realtime publishes it on the riderevent stream.
type ArrivalEvent = riderevent.ArrivalEvent

type arrivalMatch struct {
	reminder arrivalReminder
	arrival  ArrivalEvent
}

// notificationStorage is the persistence surface the dispatcher depends on,
// implemented by Store and stubbed in tests.
type notificationStorage interface {
	subscribedTokens(context.Context, string, string) ([]deviceToken, error)
	activeRemindersForArrivals(context.Context, []ArrivalEvent, time.Time) ([]arrivalMatch, error)
	dueScheduledReminders(context.Context, time.Time) ([]arrivalReminder, error)
	claim(context.Context, string, time.Time) (bool, error)
	release(context.Context, string) (bool, error)
	fired(context.Context, string, time.Time) (bool, error)
	invalidate(context.Context, string) error
}

// Dispatcher sends route-alert and arrival-reminder pushes. now is a
// clock seam for tests.
type Dispatcher struct {
	store               notificationStorage
	sender              Sender
	now                 func() time.Time
	finalizationTimeout time.Duration
	// isInvalidFCMToken reports whether an FCM send error means the token is
	// no longer registered and should be invalidated. A field (not a package
	// var) so tests can substitute the check per-instance.
	isInvalidFCMToken func(error) bool
}

const ArrivalFinalizationTimeout = 2 * time.Second

// NewDispatcher builds a dispatcher, or returns nil when sender is
// nil (push disabled). Callers must treat a nil dispatcher as "notifications off"
// — every dispatcher method is nil-safe and returns early.
func NewDispatcher(store notificationStorage, sender Sender) *Dispatcher {
	if sender == nil {
		return nil
	}
	return &Dispatcher{store: store, sender: sender, now: time.Now, finalizationTimeout: ArrivalFinalizationTimeout, isInvalidFCMToken: messaging.IsUnregistered}
}

func notificationMessage(token, title, body string, data map[string]string) *messaging.Message {
	data["title"] = title
	data["body"] = body
	return &messaging.Message{Token: token, Data: data, Notification: &messaging.Notification{Title: title, Body: body}, Android: &messaging.AndroidConfig{Priority: "high", Notification: &messaging.AndroidNotification{Sound: "default"}}, APNS: &messaging.APNSConfig{Payload: &messaging.APNSPayload{Aps: &messaging.Aps{Sound: "default"}}}}
}

type MrtVibrateEvent struct {
	ReminderID  string
	Token       string
	TrackID     string
	AlightEvent string
}

func vibrateMessage(token, trackID, alightEvent string) *messaging.Message {
	return &messaging.Message{
		Token:   token,
		Data:    map[string]string{"type": "alight_vibrate", "track_id": trackID, "event": alightEvent},
		Android: &messaging.AndroidConfig{Priority: "high"},
	}
}

// reminderMessage picks the shape a reminder's push takes: a 下車提醒 row
// vibrates silently, and a legacy arrival reminder (no alight event) keeps its
// banner. One helper so the live-ETA and scheduled paths cannot drift apart.
func reminderMessage(r arrivalReminder, title, body string, data map[string]string) *messaging.Message {
	if r.alightEvent != "" {
		return vibrateMessage(r.token, r.id, r.alightEvent)
	}
	return notificationMessage(r.token, title, body, data)
}

func (d *Dispatcher) FireMrtVibrate(ctx context.Context, event MrtVibrateEvent) (bool, error) {
	if !d.mrtVibrationEnabled(event) {
		return false, nil
	}
	return d.claimMrtVibration(ctx, event, d.now())
}

func (d *Dispatcher) claimMrtVibration(ctx context.Context, event MrtVibrateEvent, now time.Time) (bool, error) {
	claimed, err := d.store.claim(ctx, event.ReminderID, now)
	if err != nil {
		return false, _oops.With("reminder_id", event.ReminderID).Wrapf(err, "claim mrt track")
	}
	if !claimed {
		return false, nil
	}
	return d.sendClaimedMrtVibration(ctx, event, now)
}

func (d *Dispatcher) mrtVibrationEnabled(event MrtVibrateEvent) bool {
	return d != nil && event.Token != ""
}

func (d *Dispatcher) sendClaimedMrtVibration(ctx context.Context, event MrtVibrateEvent, now time.Time) (bool, error) {
	sendErr := d.sender.Send(ctx, vibrateMessage(event.Token, event.TrackID, event.AlightEvent))
	finalizationCtx, cancelFinalization := context.WithTimeout(context.WithoutCancel(ctx), d.finalizationTimeout)
	defer cancelFinalization()
	if sendErr != nil {
		return false, d.failedMrtVibrate(finalizationCtx, event, sendErr)
	}
	return d.finalizeMrtVibration(finalizationCtx, event, now)
}

func (d *Dispatcher) finalizeMrtVibration(ctx context.Context, event MrtVibrateEvent, now time.Time) (bool, error) {
	fired, err := d.store.fired(ctx, event.ReminderID, now)
	if err != nil {
		return false, _oops.With("reminder_id", event.ReminderID).Wrapf(err, "mark mrt track fired")
	}
	return fired, nil
}

func (d *Dispatcher) failedMrtVibrate(ctx context.Context, event MrtVibrateEvent, sendErr error) error {
	if err := d.invalidateMrtVibrationToken(ctx, event, sendErr); err != nil {
		return err
	}
	if _, releaseErr := d.store.release(ctx, event.ReminderID); releaseErr != nil {
		return errors.Join(_oops.With("reminder_id", event.ReminderID).Wrapf(sendErr, "send mrt vibrate"), releaseErr)
	}
	return _oops.With("reminder_id", event.ReminderID).Wrapf(sendErr, "send mrt vibrate")
}

func (d *Dispatcher) invalidateMrtVibrationToken(ctx context.Context, event MrtVibrateEvent, sendErr error) error {
	if d.isInvalidFCMToken(sendErr) {
		if invalidateErr := d.store.invalidate(ctx, event.Token); invalidateErr != nil {
			return errors.Join(_oops.With("reminder_id", event.ReminderID).Wrapf(sendErr, "send mrt vibrate"), invalidateErr)
		}
	}
	return nil
}

func (d *Dispatcher) RouteAlert(ctx context.Context, routeType, routeKey, body string) {
	if !d.routeAlertEnabled(routeType) {
		return
	}
	tokens, err := d.store.subscribedTokens(ctx, routeType, routeKey)
	if err != nil {
		zap.S().Errorw("subscriptions query failed",
			"component", "fcm",
			"action", "route_alert",
			"event", "subscriptions_query_failed",
			"route_type", routeType,
			"route_key", routeKey,
			"err", err,
		)
		return
	}
	d.sendDistinctRouteAlerts(ctx, tokens, routeType, routeKey, body)
}

func (d *Dispatcher) routeAlertEnabled(routeType string) bool {
	return d != nil && isAlertRouteType(routeType)
}

func (d *Dispatcher) sendDistinctRouteAlerts(ctx context.Context, tokens []deviceToken, routeType, routeKey, body string) {
	seen := map[string]struct{}{}
	for _, v := range tokens {
		if _, ok := seen[v.token]; ok {
			continue
		}
		seen[v.token] = struct{}{}
		d.sendRouteAlert(ctx, v.token, routeType, routeKey, body)
	}
}

func (d *Dispatcher) sendRouteAlert(ctx context.Context, token, routeType, routeKey, body string) {
	err := d.sender.Send(ctx, notificationMessage(token, alertTitle(routeKey), body, map[string]string{"kind": "route_alert", "route_type": routeType, "route_key": routeKey}))
	if d.isInvalidFCMToken(err) {
		_ = d.store.invalidate(ctx, token)
	} else if err != nil {
		zap.S().Warnw("send failed",
			"component", "fcm",
			"action", "route_alert",
			"event", "send_failed",
			"route_type", routeType,
			"route_key", routeKey,
			"err", err,
		)
	}
}

// isAlertRouteType reports whether a transit type can carry disruption alerts.
// It mirrors the route_type CHECK constraint on firebase_route_subscription.
func isAlertRouteType(routeType string) bool {
	switch routeType {
	case "bus", "mrt", "tra", "thsr":
		return true
	}
	return false
}

// alertTitle labels a disruption by how wide it is: a keyed alert names one
// route, an unkeyed one is line-wide.
func alertTitle(routeKey string) string {
	if routeKey == "" {
		return "營運通阻"
	}
	return "路線異常"
}

// arrivalReminderBody renders the live-ETA reminder text. Zero minutes means
// the vehicle is entering the stop now (the MQTT near-stop trigger), where
// 「預計 0 分鐘後到站」would read as broken copy.
func arrivalReminderBody(minutes int32) string {
	if minutes <= 0 {
		return "即將進站"
	}
	return fmt.Sprintf("預計 %d 分鐘後到站", minutes)
}

func sameArrivalIdentity(left, right ArrivalEvent) bool {
	return left.RouteType == right.RouteType && left.RouteKey == right.RouteKey &&
		left.StopKey == right.StopKey && left.Direction == right.Direction
}

// Arrivals dispatches one collection of live arrival observations with one
// reminder lookup. Claim, send, and final state errors are joined so no failed
// transition is hidden from the cron runner.
func (d *Dispatcher) Arrivals(ctx context.Context, events []ArrivalEvent) error {
	if d == nil {
		return nil
	}
	eligible := eligibleArrivalEvents(events)
	if len(eligible) == 0 {
		return nil
	}
	return d.dispatchEligibleArrivals(ctx, eligible)
}

func (d *Dispatcher) dispatchEligibleArrivals(ctx context.Context, eligible []ArrivalEvent) error {
	now := d.now()
	matches, err := d.store.activeRemindersForArrivals(ctx, eligible, now)
	if err != nil {
		return _oops.Wrapf(err, "load arrival reminders")
	}
	return d.dispatchArrivalMatches(ctx, matches, now)
}

func (d *Dispatcher) dispatchArrivalMatches(ctx context.Context, matches []arrivalMatch, now time.Time) error {
	var dispatchErr error
	for _, match := range matches {
		stop, err := dispatchReminderStep(ctx, func() (bool, error) { return d.dispatchArrivalMatch(ctx, match, now) })
		dispatchErr = errors.Join(dispatchErr, err)
		if stop {
			break
		}
	}

	return dispatchErr
}

func (d *Dispatcher) dispatchArrivalMatch(ctx context.Context, match arrivalMatch, now time.Time) (bool, error) {
	if !matchesArrivalReminder(match) {
		return false, nil
	}
	r, event := match.reminder, match.arrival
	msg := reminderMessage(r, "即將到站", arrivalReminderBody((event.ETASeconds+59)/60), reminderMessageData(r))
	return d.dispatchReminder(ctx, r, now, msg, "arrival")
}

func dispatchReminderStep(ctx context.Context, dispatch func() (bool, error)) (bool, error) {
	if err := ctx.Err(); err != nil {
		return true, err
	}
	finalized, err := dispatch()
	if ctxErr := afterReminderFinalization(ctx, finalized); ctxErr != nil {
		return true, errors.Join(err, ctxErr)
	}
	return false, err
}

func eligibleArrivalEvents(events []ArrivalEvent) []ArrivalEvent {
	eligible := make([]ArrivalEvent, 0, len(events))
	for _, event := range events {
		if event.ETASeconds >= 0 {
			eligible = append(eligible, event)
		}
	}
	return eligible
}

func matchesArrivalReminder(match arrivalMatch) bool {
	r, event := match.reminder, match.arrival
	return sameArrivalIdentity(event, ArrivalEvent{RouteType: r.routeType, RouteKey: r.routeKey, StopKey: r.stopKey, Direction: r.direction}) && reminderArrivalInWindow(r, event) && reminderPlateMatches(r, event)
}

func reminderArrivalInWindow(r arrivalReminder, event ArrivalEvent) bool {
	return event.ETASeconds >= 0 && event.ETASeconds <= int32(r.leadMinutes*60)
}
func reminderPlateMatches(r arrivalReminder, event ArrivalEvent) bool {
	return r.plate == "" || r.plate == event.ArrivingPlate
}

func reminderMessageData(r arrivalReminder) map[string]string {
	return map[string]string{"kind": "arrival_reminder", "route_type": r.routeType, "route_key": r.routeKey, "stop_key": r.stopKey, "direction": r.direction, "lead_minutes": strconv.Itoa(r.leadMinutes)}
}

func (d *Dispatcher) FireScheduled(ctx context.Context) error {
	if d == nil {
		return nil
	}
	now := d.now()
	reminders, err := d.store.dueScheduledReminders(ctx, now)
	if err != nil {
		return _oops.Wrapf(err, "load scheduled reminders")
	}
	return d.dispatchScheduledReminders(ctx, reminders, now)
}

func (d *Dispatcher) dispatchScheduledReminders(ctx context.Context, reminders []arrivalReminder, now time.Time) error {
	var dispatchErr error
	for _, r := range reminders {
		stop, err := dispatchReminderStep(ctx, func() (bool, error) {
			msg := reminderMessage(r, "即將到站", fmt.Sprintf("預計 %d 分鐘後到站", r.leadMinutes), reminderMessageData(r))
			return d.dispatchReminder(ctx, r, now, msg, "scheduled")
		})
		dispatchErr = errors.Join(dispatchErr, err)
		if stop {
			break
		}
	}
	return dispatchErr
}

func (d *Dispatcher) dispatchReminder(ctx context.Context, r arrivalReminder, now time.Time, msg *messaging.Message, kind string) (bool, error) {
	claimed, err := d.store.claim(ctx, r.id, now)
	if err != nil {
		return false, _oops.With("r_id", r.id).Wrapf(err, "claim %s reminder", kind)
	}
	if !claimed {
		return false, nil
	}
	return d.sendClaimedReminder(ctx, r, now, msg, kind)
}

func (d *Dispatcher) sendClaimedReminder(ctx context.Context, r arrivalReminder, now time.Time, msg *messaging.Message, kind string) (bool, error) {
	sendErr := d.sender.Send(ctx, msg)
	finalizationCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), d.finalizationTimeout)
	defer cancel()
	if sendErr != nil {
		return true, d.failedReminderSend(finalizationCtx, r, sendErr, kind)
	}
	return d.finalizeReminder(finalizationCtx, r, now, kind)
}

func (d *Dispatcher) finalizeReminder(ctx context.Context, r arrivalReminder, now time.Time, kind string) (bool, error) {
	fired, err := d.store.fired(ctx, r.id, now)
	if err != nil {
		return true, _oops.With("r_id", r.id).Wrapf(err, "mark %s reminder fired", kind)
	}
	if !fired {
		return true, _oops.With("r_id", r.id).Errorf("mark %s reminder fired changed no rows", kind)
	}
	return true, nil
}

func (d *Dispatcher) failedReminderSend(ctx context.Context, r arrivalReminder, sendErr error, kind string) error {
	invalidateErr := d.invalidateFailedReminderToken(ctx, r, sendErr, kind)
	releaseErr := d.releaseFailedReminder(ctx, r, kind)
	return errors.Join(invalidateErr, releaseErr, _oops.With("r_id", r.id).Wrapf(sendErr, "send %s reminder", kind))
}

func (d *Dispatcher) invalidateFailedReminderToken(ctx context.Context, r arrivalReminder, sendErr error, kind string) error {
	if d.isInvalidFCMToken(sendErr) {
		if err := d.store.invalidate(ctx, r.token); err != nil {
			return _oops.Wrapf(err, "invalidate %s reminder token", kind)
		}
	}
	return nil
}

func (d *Dispatcher) releaseFailedReminder(ctx context.Context, r arrivalReminder, kind string) error {
	released, err := d.store.release(ctx, r.id)
	if err != nil {
		return _oops.With("r_id", r.id).Wrapf(err, "release %s reminder", kind)
	}
	if !released {
		return _oops.With("r_id", r.id).Errorf("release %s reminder changed no rows", kind)
	}
	return nil
}

func afterReminderFinalization(ctx context.Context, finalized bool) error {
	if !finalized {
		return nil
	}
	return ctx.Err()
}
