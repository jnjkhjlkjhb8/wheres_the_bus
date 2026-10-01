package notify

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"firebase.google.com/go/v4/messaging"
	"go.uber.org/zap"
)

// ArrivalEvent is one live vehicle arrival considered for reminder dispatch.
type ArrivalEvent struct {
	RouteType     string `json:"route_type"`
	RouteKey      string `json:"route_key"`
	StopKey       string `json:"stop_key"`
	Direction     string `json:"direction"`
	ETASeconds    int32  `json:"eta_seconds"`
	ArrivingPlate string `json:"arriving_plate"`
}

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
	if d == nil || event.Token == "" {
		return false, nil
	}
	now := d.now()
	claimed, err := d.store.claim(ctx, event.ReminderID, now)
	if err != nil {
		return false, _oops.With("reminder_id", event.ReminderID).Wrapf(err, "claim mrt track")
	}
	if !claimed {
		return false, nil
	}
	sendErr := d.sender.Send(ctx, vibrateMessage(event.Token, event.TrackID, event.AlightEvent))
	finalizationCtx, cancelFinalization := context.WithTimeout(context.WithoutCancel(ctx), d.finalizationTimeout)
	defer cancelFinalization()
	if sendErr != nil {
		if d.isInvalidFCMToken(sendErr) {
			if invalidateErr := d.store.invalidate(finalizationCtx, event.Token); invalidateErr != nil {
				return false, errors.Join(_oops.With("reminder_id", event.ReminderID).Wrapf(sendErr, "send mrt vibrate"), invalidateErr)
			}
		}
		if _, releaseErr := d.store.release(finalizationCtx, event.ReminderID); releaseErr != nil {
			return false, errors.Join(_oops.With("reminder_id", event.ReminderID).Wrapf(sendErr, "send mrt vibrate"), releaseErr)
		}
		return false, _oops.With("reminder_id", event.ReminderID).Wrapf(sendErr, "send mrt vibrate")
	}
	fired, err := d.store.fired(finalizationCtx, event.ReminderID, now)
	if err != nil {
		return false, _oops.With("reminder_id", event.ReminderID).Wrapf(err, "mark mrt track fired")
	}
	return fired, nil
}

func (d *Dispatcher) routeAlert(ctx context.Context, routeType, routeKey, body string) {
	if d == nil || !isAlertRouteType(routeType) {
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
	seen := map[string]struct{}{}
	for _, v := range tokens {
		if _, ok := seen[v.token]; ok {
			continue
		}
		seen[v.token] = struct{}{}
		err = d.sender.Send(ctx, notificationMessage(v.token, alertTitle(routeKey), body, map[string]string{"kind": "route_alert", "route_type": routeType, "route_key": routeKey}))
		if d.isInvalidFCMToken(err) {
			_ = d.store.invalidate(ctx, v.token)
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
	if d == nil || len(events) == 0 {
		return nil
	}
	eligible := make([]ArrivalEvent, 0, len(events))
	for _, event := range events {
		if event.ETASeconds >= 0 {
			eligible = append(eligible, event)
		}
	}
	if len(eligible) == 0 {
		return nil
	}
	now := d.now()
	matches, err := d.store.activeRemindersForArrivals(ctx, eligible, now)
	if err != nil {
		return _oops.Wrapf(err, "load arrival reminders")
	}
	var dispatchErr error
	for _, match := range matches {
		if ctxErr := ctx.Err(); ctxErr != nil {
			dispatchErr = errors.Join(dispatchErr, ctxErr)
			break
		}
		r, event := match.reminder, match.arrival
		if !sameArrivalIdentity(event, ArrivalEvent{
			RouteType: r.routeType, RouteKey: r.routeKey, StopKey: r.stopKey, Direction: r.direction,
		}) || event.ETASeconds < 0 || event.ETASeconds > int32(r.leadMinutes*60) ||
			(r.plate != "" && r.plate != event.ArrivingPlate) {
			continue
		}
		claimed, claimErr := d.store.claim(ctx, r.id, now)
		if claimErr != nil {
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(claimErr, "claim arrival reminder"))
			continue
		}
		if !claimed {
			continue
		}
		msg := reminderMessage(r, "即將到站", arrivalReminderBody((event.ETASeconds+59)/60), map[string]string{"kind": "arrival_reminder", "route_type": r.routeType, "route_key": r.routeKey, "stop_key": r.stopKey, "direction": r.direction, "lead_minutes": strconv.Itoa(r.leadMinutes)})
		sendErr := d.sender.Send(ctx, msg)
		finalizationCtx, cancelFinalization := context.WithTimeout(context.WithoutCancel(ctx), d.finalizationTimeout)
		if sendErr != nil {
			if d.isInvalidFCMToken(sendErr) {
				if invalidateErr := d.store.invalidate(finalizationCtx, r.token); invalidateErr != nil {
					dispatchErr = errors.Join(dispatchErr, _oops.Wrapf(invalidateErr, "invalidate arrival reminder token"))
				}
			}
			released, releaseErr := d.store.release(finalizationCtx, r.id)
			if releaseErr != nil {
				dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(releaseErr, "release arrival reminder"))
			} else if !released {
				dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Errorf("release arrival reminder changed no rows"))
			}
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(sendErr, "send arrival reminder"))
			cancelFinalization()
			if ctxErr := ctx.Err(); ctxErr != nil {
				dispatchErr = errors.Join(dispatchErr, ctxErr)
				break
			}
			continue
		}
		fired, firedErr := d.store.fired(finalizationCtx, r.id, now)
		cancelFinalization()
		if firedErr != nil {
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(firedErr, "mark arrival reminder fired"))
		} else if !fired {
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Errorf("mark arrival reminder fired changed no rows"))
		}
		if ctxErr := ctx.Err(); ctxErr != nil {
			dispatchErr = errors.Join(dispatchErr, ctxErr)
			break
		}
	}
	return dispatchErr
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
	var dispatchErr error
	for _, r := range reminders {
		if ctxErr := ctx.Err(); ctxErr != nil {
			dispatchErr = errors.Join(dispatchErr, ctxErr)
			break
		}
		claimed, claimErr := d.store.claim(ctx, r.id, now)
		if claimErr != nil {
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(claimErr, "claim scheduled reminder"))
			continue
		}
		if !claimed {
			continue
		}
		msg := reminderMessage(r, "即將到站", fmt.Sprintf("預計 %d 分鐘後到站", r.leadMinutes), map[string]string{"kind": "arrival_reminder", "route_type": r.routeType, "route_key": r.routeKey, "stop_key": r.stopKey, "direction": r.direction, "lead_minutes": strconv.Itoa(r.leadMinutes)})
		sendErr := d.sender.Send(ctx, msg)
		finalizationCtx, cancelFinalization := context.WithTimeout(context.WithoutCancel(ctx), d.finalizationTimeout)
		if sendErr != nil {
			if d.isInvalidFCMToken(sendErr) {
				if invalidateErr := d.store.invalidate(finalizationCtx, r.token); invalidateErr != nil {
					dispatchErr = errors.Join(dispatchErr, _oops.Wrapf(invalidateErr, "invalidate scheduled reminder token"))
				}
			}
			released, releaseErr := d.store.release(finalizationCtx, r.id)
			if releaseErr != nil {
				dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(releaseErr, "release scheduled reminder"))
			} else if !released {
				dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Errorf("release scheduled reminder changed no rows"))
			}
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(sendErr, "send scheduled reminder"))
			cancelFinalization()
			if ctxErr := ctx.Err(); ctxErr != nil {
				dispatchErr = errors.Join(dispatchErr, ctxErr)
				break
			}
			continue
		}
		fired, firedErr := d.store.fired(finalizationCtx, r.id, now)
		cancelFinalization()
		if firedErr != nil {
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Wrapf(firedErr, "mark scheduled reminder fired"))
		} else if !fired {
			dispatchErr = errors.Join(dispatchErr, _oops.With("r_id", r.id).Errorf("mark scheduled reminder fired changed no rows"))
		}
		if ctxErr := ctx.Err(); ctxErr != nil {
			dispatchErr = errors.Join(dispatchErr, ctxErr)
			break
		}
	}
	return dispatchErr
}
