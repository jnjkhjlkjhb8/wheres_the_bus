package mrttrack

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/notify"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// Metro session status values carried in MrtTrackState.status. tracking and
// lead_fired are live; the rest are terminal endings surfaced only on the card.
const (
	_mrtStatusTracking  = "tracking"
	_mrtStatusLeadFired = "lead_fired"
	_mrtStatusArrived   = "arrived"
	_mrtStatusLost      = "lost"
	_mrtStatusStale     = "stale"
	_mrtStatusCancelled = "cancelled"
)

const (
	// _mrtTrackActiveTTL keeps a live session's Redis state slightly beyond the
	// reminder's own 3h expiry so a watcher always has state to seed from.
	_mrtTrackActiveTTL = 3 * time.Hour
	// _mrtTrackEndedTTL keeps a terminal state briefly so connected watchers
	// receive the ending before the key disappears.
	_mrtTrackEndedTTL = 60 * time.Second
	// _mrtTrackStaleAfter ends a session that has not advanced within this window
	// (a lost binding the position resolver could not classify as off-path, a
	// stalled train, or a persistent feed gap).
	_mrtTrackStaleAfter = 10 * time.Minute
	// _mrtTrackPollBuffer pads the parsed countdown so the next poll lands just
	// after the train is due at its next station, not before.
	_mrtTrackPollBuffer = 10 * time.Second
	// _mrtTrackFallbackRetry is the retry delay after an empty/failed GetTrainInfo
	// (including the mrt_live fallback path), where no countdown is available.
	_mrtTrackFallbackRetry = 30 * time.Second
	// TickTimeout bounds one whole tracker tick under its 15s cadence.
	TickTimeout = 12 * time.Second
)

// trainInfoClient is the GetTrainInfo seam the tracker depends on, satisfied by
// *shared.TRTCTrainInfoClient and stubbed in tests.
type trainInfoClient interface {
	GetTrainInfo(ctx context.Context, carID string) (*shared.TRTCTrainInfo, bool, error)
}

// mrtTrackStore is the reminder-enumeration seam: which sessions are active and
// how to drop a never-fired one whose Redis state has ended.
type mrtTrackStore interface {
	ActiveMrtTracks(ctx context.Context, now time.Time) ([]notify.MrtTrackReminder, error)
	ExpireMrtTrack(ctx context.Context, id string) error
}

// mrtVibrator fires the lead vibration exactly once, satisfied by
// *notify.Dispatcher (nil-safe when push is disabled).
type mrtVibrator interface {
	FireMrtVibrate(ctx context.Context, event notify.MrtVibrateEvent) (bool, error)
}

// mrtCardPusher refreshes the rider's tracking card over push, satisfied by
// *notify.TrackPusher (nil-safe when neither transport is configured).
type mrtCardPusher interface {
	PushCard(ctx context.Context, card notify.AlightCard, target notify.CardTarget, alert *notify.CardAlert) error
}

// mrtTracker holds the tracker's dependencies for one deployment.
type mrtTracker struct {
	trtc     trainInfoClient
	rc       *redis.Client
	store    mrtTrackStore
	vibrator mrtVibrator
	pusher   mrtCardPusher
}

// tick advances every due session once. Per-session failures are logged and do
// not abort the others.
func (t *mrtTracker) Tick(ctx context.Context, now time.Time) {
	tracks, err := t.store.ActiveMrtTracks(ctx, now)
	if err != nil {
		zap.S().Errorw("list error", "component", "mrt_track", "action", "tick", "event", "list_error", "err", err)
		return
	}
	if len(tracks) == 0 {
		return
	}
	zap.S().Infow("start", "component", "mrt_track", "action", "tick", "event", "start", "sessions", len(tracks))
	for _, track := range tracks {
		if ctx.Err() != nil {
			return
		}
		t.advanceSession(ctx, track, now)
	}
}

// advanceSession processes one session: read its Redis state, skip it unless a
// poll is due, acquire a reading, apply the pure advance decision, fire the lead
// vibration once, and persist + publish the new state.
func (t *mrtTracker) advanceSession(ctx context.Context, track notify.MrtTrackReminder, now time.Time) {
	raw, err := t.rc.Get(ctx, shared.MrtTrackKey(track.ID)).Bytes()
	if errors.Is(err, redis.Nil) {
		// The session's state has ended and its key expired (or was never
		// written). Drop a never-fired row so the active query stops returning it;
		// a fired row ages out on expires_at (its status cannot move — CHECK).
		if expireErr := t.store.ExpireMrtTrack(ctx, track.ID); expireErr != nil {
			zap.S().Warnw("expire error",
				"component", "mrt_track",
				"action", "advance",
				"event", "expire_error",
				"track", track.ID,
				"err", expireErr,
			)
		}
		return
	}
	if err != nil {
		zap.S().Warnw("state read error",
			"component", "mrt_track",
			"action", "advance",
			"event", "state_read_error",
			"track", track.ID,
			"err", err,
		)
		return
	}
	var state models.MrtTrackState
	if err := proto.Unmarshal(raw, &state); err != nil {
		zap.S().Warnw("state decode error",
			"component", "mrt_track",
			"action", "advance",
			"event", "state_decode_error",
			"track", track.ID,
			"err", err,
		)
		return
	}
	if mrtIsTerminal(state.Status) {
		return
	}
	if now.Unix() < state.NextPollAtUnix {
		return
	}

	reading := t.readPosition(ctx, &state)
	newState, fire := advanceMrtTrack(&state, reading, now)

	if fire != "" && track.Token != "" {
		// Each event owns its own reminder row, so each claims and fires once.
		reminderID := track.ID
		if fire == _mrtAlightEventLead {
			reminderID = track.ID + ":lead"
		}
		fired, fireErr := t.vibrator.FireMrtVibrate(ctx, notify.MrtVibrateEvent{
			ReminderID: reminderID, Token: track.Token, TrackID: track.ID, AlightEvent: fire,
		})
		if fireErr != nil {
			zap.S().Warnw("vibrate error",
				"component", "mrt_track",
				"action", "advance",
				"event", "vibrate_error",
				"track", track.ID,
				"err", fireErr,
			)
		} else if fired {
			zap.S().Infow("vibrate fired",
				"component", "mrt_track",
				"action", "advance",
				"event", "vibrate_fired",
				"track", track.ID,
				"buzz", fire,
				"remaining", newState.RemainingStops,
			)
		}
	}

	t.publishState(ctx, newState)
	t.pushCard(ctx, &state, newState, track, fire, now)
	if mrtIsTerminal(newState.Status) {
		zap.S().Infow("ended",
			"component", "mrt_track",
			"action", "advance",
			"event", "ended",
			"track", track.ID,
			"status", newState.Status,
		)
		if expireErr := t.store.ExpireMrtTrack(ctx, track.ID); expireErr != nil {
			zap.S().Warnw("expire error",
				"component", "mrt_track",
				"action", "advance",
				"event", "expire_error",
				"track", track.ID,
				"err", expireErr,
			)
		}
	}
}

const _mrtCardStaleAfter = 6 * time.Minute

func (t *mrtTracker) pushCard(
	ctx context.Context,
	previous, next *models.MrtTrackState,
	track notify.MrtTrackReminder,
	fire string,
	now time.Time,
) {
	if t.pusher == nil || !mrtCardMoved(previous, next) {
		return
	}
	target := notify.CardTarget{FCMToken: track.Token}
	// Absent on Android, and on an iOS app that never got a card: the key is
	// written only once ActivityKit hands the app a token for a live activity.
	if token, err := t.rc.Get(ctx, shared.MrtTrackPushTokenKey(track.ID)).Result(); err == nil {
		target.ActivityToken = token
	} else if !errors.Is(err, redis.Nil) {
		zap.S().Warnw("push token read error",
			"component", "mrt_track",
			"action", "push",
			"event", "push_token_read_error",
			"track", track.ID,
			"err", err,
		)
	}
	if target.FCMToken == "" && target.ActivityToken == "" {
		return
	}

	card := mrtCard(next, now)
	alert := mrtCardAlert(fire, card)
	if err := t.pusher.PushCard(ctx, card, target, alert); err != nil {
		zap.S().Warnw("push error",
			"component", "mrt_track",
			"action", "push",
			"event", "push_error",
			"track", track.ID,
			"err", err,
		)
		return
	}
	zap.S().Infow("pushed",
		"component", "mrt_track",
		"action", "push",
		"event", "pushed",
		"track", track.ID,
		"phase", card.Phase,
		"remaining", card.RemainingStops,
	)
}

// mrtCardMoved reports whether anything the card shows actually changed. The
// poll schedule moving is not a change the rider can see.
func mrtCardMoved(previous, next *models.MrtTrackState) bool {
	return previous.CurrentIndex != next.CurrentIndex ||
		previous.RemainingStops != next.RemainingStops ||
		previous.Status != next.Status ||
		previous.NextStationName != next.NextStationName
}

func mrtCard(state *models.MrtTrackState, now time.Time) notify.AlightCard {
	hopCount := max(state.TargetIndex, 1)
	remaining := min(max(state.RemainingStops, 0), hopCount)
	return notify.AlightCard{
		TrackID: state.TrackId,
		Mode:    "metro",
		Phase:   mrtCardPhase(state.Status, remaining, state.LeadStops),
		// The rider knows which line they are on, not which trip id they are on,
		// so the app hands these up at CreateTrack and they ride back out here.
		VehicleLabel:   state.VehicleLabel,
		VehicleID:      state.CarId,
		BoardStation:   mrtPathName(state, 0),
		TargetStation:  mrtPathName(state, state.TargetIndex),
		NextStation:    state.NextStationName,
		HopCount:       hopCount,
		CurrentIndex:   min(max(state.CurrentIndex, 0), hopCount),
		RemainingStops: remaining,
		LeadStops:      state.LeadStops,
		LineCode:       state.LineCode,
		LineColorHex:   state.LineColorHex,
		AsOf:           now,
		StaleAfter:     _mrtCardStaleAfter,
	}
}

func mrtCardPhase(status string, remaining, lead int32) string {
	switch status {
	case _mrtStatusArrived:
		return "arrived"
	case _mrtStatusLost, _mrtStatusStale, _mrtStatusCancelled:
		return "lost"
	}
	if remaining <= lead+1 {
		return "approaching"
	}
	return "riding"
}

// mrtCardAlert turns a crossing into the words the iOS card alerts with. Nothing
// crossed means no alert: the card still refreshes, it just does so quietly.
func mrtCardAlert(fire string, card notify.AlightCard) *notify.CardAlert {
	switch fire {
	case _mrtAlightEventAlight:
		alert := notify.AlightAlert(card.TargetStation)
		return &alert
	case _mrtAlightEventLead:
		alert := notify.LeadAlert(card.RemainingStops, card.TargetStation)
		return &alert
	}
	return nil
}

// mrtPathName reads a path station's display name, tolerating a path shorter
// than the index asks for rather than failing a push over a missing string.
func mrtPathName(state *models.MrtTrackState, index int32) string {
	if index < 0 || int(index) >= len(state.PathStationNames) {
		return ""
	}
	return state.PathStationNames[index]
}

// publishState writes the session state to its Redis key (short TTL once
// terminal so it lingers only long enough for connected watchers) and publishes
// it on the session channel.
func (t *mrtTracker) publishState(ctx context.Context, state *models.MrtTrackState) {
	pb, err := proto.Marshal(state)
	if err != nil {
		zap.S().Warnw("encode error",
			"component", "mrt_track",
			"action", "publish",
			"event", "encode_error",
			"track", state.TrackId,
			"err", err,
		)
		return
	}
	ttl := _mrtTrackActiveTTL
	if mrtIsTerminal(state.Status) {
		ttl = _mrtTrackEndedTTL
	}
	rc := t.rc
	if err := rc.Set(ctx, shared.MrtTrackKey(state.TrackId), pb, ttl).Err(); err != nil {
		zap.S().Warnw("set error",
			"component", "mrt_track",
			"action", "publish",
			"event", "set_error",
			"track", state.TrackId,
			"err", err,
		)
		return
	}
	if err := rc.Publish(ctx, shared.MrtTrackChannel(state.TrackId), pb).Err(); err != nil {
		zap.S().Warnw("publish error",
			"component", "mrt_track",
			"action", "publish",
			"event", "publish_error",
			"track", state.TrackId,
			"err", err,
		)
	}
}

func (t *mrtTracker) readPosition(ctx context.Context, state *models.MrtTrackState) mrtReading {
	info, ok, err := t.trtc.GetTrainInfo(ctx, state.CarId)
	if err != nil {
		zap.S().Warnw("traininfo error",
			"component", "mrt_track",
			"action", "read",
			"event", "traininfo_error",
			"track", state.TrackId,
			"err", err,
		)
		return mrtReading{}
	}
	if ok {
		if info.TripID != state.TripId {
			// The carID now reports a different trip — the train re-tripped or
			// turned around, so the binding no longer follows this rider's ride.
			return mrtReading{lost: true}
		}
		idx := mrtResolvePathIndex(state.PathStationNames, info.StnName)
		countdown, hasCountdown := parseTrtcTrainCountdown(info.CountdownTime)
		if idx < 0 {
			// An empty StnName is a transient mid-run gap (retry); a non-empty name
			// that is not on the stored path means the train left the path.
			if strings.TrimSpace(strings.TrimSuffix(info.StnName, "站")) == "" {
				return mrtReading{gotInfo: true}
			}
			return mrtReading{lost: true}
		}
		return mrtReading{nextIndex: idx, countdown: countdown, hasCountdown: hasCountdown, gotInfo: true, resolved: true}
	}
	// GetTrainInfo empty: advance from mrt_live by TripId until it recovers.
	if idx, found := t.fallbackFromLive(ctx, state); found {
		return mrtReading{nextIndex: idx, resolved: true}
	}
	return mrtReading{}
}

func (t *mrtTracker) fallbackFromLive(ctx context.Context, state *models.MrtTrackState) (int, bool) {
	if len(state.PathStationIds) == 0 {
		return 0, false
	}
	rc := t.rc
	// The terminal is the last station on the board→terminal path; it is part of
	// the mrt_live key identity (a station has simultaneous arrivals per direction).
	terminal := state.PathStationIds[len(state.PathStationIds)-1]
	start := int(state.CurrentIndex) + 1
	for idx := start; idx < len(state.PathStationIds); idx++ {
		station := state.PathStationIds[idx]
		line := shared.TrtcLinePrefix(station)
		raw, err := rc.Get(ctx, shared.MrtLiveKey("TRTC", station, line, terminal)).Bytes()
		if err != nil {
			// A miss is the normal case: most stations on the path have no live
			// arrival for this terminal. Anything else is a real Redis fault and
			// would otherwise vanish, since the fallback reports only found/not.
			if !errors.Is(err, redis.Nil) {
				zap.S().Warnw("redis error",
					"component", "mrt_track",
					"action", "fallback_live",
					"event", "redis_error",
					"station", station,
					"err", err,
				)
			}
			continue
		}
		var live models.MrtLive
		if err := proto.Unmarshal(raw, &live); err != nil {
			zap.S().Warnw("decode error",
				"component", "mrt_track",
				"action", "fallback_live",
				"event", "decode_error",
				"station", station,
				"err", err,
			)
			continue
		}
		if live.TrainNumber == state.TripId {
			return idx, true
		}
	}
	return 0, false
}

type mrtReading struct {
	nextIndex    int
	countdown    time.Duration
	hasCountdown bool
	gotInfo      bool
	resolved     bool
	lost         bool
}

const (
	_mrtAlightEventLead   = "lead"
	_mrtAlightEventAlight = "alight"
)

func mrtFireEvent(remaining, lead int32) string {
	switch {
	case remaining <= 1:
		return _mrtAlightEventAlight
	case lead > 0 && remaining <= lead+1:
		return _mrtAlightEventLead
	}
	return ""
}

func advanceMrtTrack(state *models.MrtTrackState, reading mrtReading, now time.Time) (*models.MrtTrackState, string) {
	next, ok := proto.Clone(state).(*models.MrtTrackState)
	if !ok {
		zap.S().Errorw("clone failed",
			"component", "mrt_track", "action", "advance", "event", "clone_failed")
		return state, ""
	}
	target := next.TargetIndex

	finishing := state.CurrentIndex >= target-1
	if reading.lost {
		if !finishing {
			next.Status = _mrtStatusLost
			next.NextPollAtUnix = 0
			return next, ""
		}
		reading = mrtReading{nextIndex: int(target) + 1, resolved: true}
	}

	advanced := false
	if reading.resolved {
		// The reading is the train's next station; the last passed station is one
		// before it. Guard against any backward movement.
		candidate := int32(reading.nextIndex - 1)
		if candidate > next.CurrentIndex {
			next.CurrentIndex = candidate
			next.LastProgressAtUnix = now.Unix()
			advanced = true
		}
	}

	if next.CurrentIndex >= target {
		next.CurrentIndex = target
	}
	next.RemainingStops = target - next.CurrentIndex
	if next.RemainingStops < 0 {
		next.RemainingStops = 0
	}
	next.NextStationId, next.NextStationName = mrtNextStation(next)
	next.Progress = 1
	if target > 0 {
		next.Progress = float64(next.CurrentIndex) / float64(target)
	}

	fire := mrtFireEvent(next.RemainingStops, next.LeadStops)

	switch {
	case next.CurrentIndex >= target:
		next.Status = _mrtStatusArrived
		next.NextPollAtUnix = 0
		return next, fire
	case !advanced && mrtStale(state.LastProgressAtUnix, now):
		if finishing {
			// Stalled within one stop of the target (typically a persistently empty
			// GetTrainInfo at the end of a run): report the ride completed.
			next.CurrentIndex = target
			next.RemainingStops = 0
			next.Progress = 1
			next.NextStationId, next.NextStationName = mrtNextStation(next)
			next.Status = _mrtStatusArrived
			next.NextPollAtUnix = 0
			return next, fire
		}
		next.Status = _mrtStatusStale
		next.NextPollAtUnix = 0
		return next, ""
	case fire != "":
		// The status is the card's "we are inside the warning window" reading,
		// so it follows whichever buzz is owed rather than the lead alone —
		// otherwise a default session (提前站數 0) would never show it.
		next.Status = _mrtStatusLeadFired
	default:
		next.Status = _mrtStatusTracking
	}

	next.NextPollAtUnix = now.Add(_mrtTrackFallbackRetry).Unix()
	if reading.gotInfo && reading.hasCountdown && reading.countdown > 0 {
		next.NextPollAtUnix = now.Add(reading.countdown + _mrtTrackPollBuffer).Unix()
	}
	return next, fire
}

// mrtNextStation returns the station the train is heading toward: the one after
// the last passed. Past the terminal it is empty.
func mrtNextStation(state *models.MrtTrackState) (string, string) {
	nextIdx := int(state.CurrentIndex) + 1
	if nextIdx < 0 || nextIdx >= len(state.PathStationIds) {
		return "", ""
	}
	name := ""
	if nextIdx < len(state.PathStationNames) {
		name = state.PathStationNames[nextIdx]
	}
	return state.PathStationIds[nextIdx], name
}

// mrtStale reports whether the position has not advanced within the stale
// window. A zero lastProgress (never advanced since creation) is measured from
// now on the first tick, so a session only goes stale after a real gap.
func mrtStale(lastProgressUnix int64, now time.Time) bool {
	if lastProgressUnix <= 0 {
		return false
	}
	return now.Sub(time.Unix(lastProgressUnix, 0)) > _mrtTrackStaleAfter
}

// mrtIsTerminal reports whether a status is an ending (no further advancement).
func mrtIsTerminal(status string) bool {
	switch status {
	case _mrtStatusArrived, _mrtStatusLost, _mrtStatusStale, _mrtStatusCancelled:
		return true
	}
	return false
}

// mrtResolvePathIndex resolves a GetTrainInfo StnName to a path index, matching
// against the stored path names only. It strips the 「站」suffix and absorbs the
// same feed misspellings the live job aliases; an empty or off-path name is -1.
func mrtResolvePathIndex(names []string, stnName string) int {
	trimmed := strings.TrimSuffix(stnName, "站")
	if aliased, ok := shared.TrtcAliases[trimmed]; ok {
		trimmed = aliased
	}
	if strings.TrimSpace(trimmed) == "" {
		return -1
	}
	for i, name := range names {
		if name == trimmed || name == stnName {
			return i
		}
	}
	return -1
}

// parseTrtcTrainCountdown parses GetTrainInfo's "mm:ss" CountdownTime to the next
// station. Anything else carries no schedule, so the next poll uses the short
// fallback interval instead.
func parseTrtcTrainCountdown(s string) (time.Duration, bool) {
	total, ok := shared.ParseMMSS(s)
	if !ok {
		return 0, false
	}
	return time.Duration(total) * time.Second, true
}

// NewTracker wires one alight-tracking tick: the train-info client it polls, the
// Redis client the card state lives in, the session store, and the two ways a
// rider is told to get off.
func NewTracker(trtc trainInfoClient, rc *redis.Client, store mrtTrackStore, vibrator mrtVibrator, pusher mrtCardPusher) *mrtTracker {
	return &mrtTracker{trtc: trtc, rc: rc, store: store, vibrator: vibrator, pusher: pusher}
}
