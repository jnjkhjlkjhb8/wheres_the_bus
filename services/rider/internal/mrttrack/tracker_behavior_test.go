package mrttrack

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/notify"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"google.golang.org/protobuf/proto"
)

type trackerStore struct {
	tracks             []notify.MrtTrackReminder
	expired            []string
	listErr, expireErr error
}

func (s *trackerStore) ActiveMrtTracks(context.Context, time.Time) ([]notify.MrtTrackReminder, error) {
	return s.tracks, s.listErr
}
func (s *trackerStore) ExpireMrtTrack(_ context.Context, id string) error {
	s.expired = append(s.expired, id)
	return s.expireErr
}

type trackerTrain struct {
	info  *shared.TRTCTrainInfo
	found bool
	err   error
}

func (f *trackerTrain) GetTrainInfo(context.Context, string) (*shared.TRTCTrainInfo, bool, error) {
	return f.info, f.found, f.err
}

type trackerVibrator struct {
	events []notify.MrtVibrateEvent
	err    error
}

func (v *trackerVibrator) FireMrtVibrate(_ context.Context, e notify.MrtVibrateEvent) (bool, error) {
	v.events = append(v.events, e)
	return v.err == nil, v.err
}

type trackerPusher struct {
	cards   []notify.AlightCard
	targets []notify.CardTarget
	alerts  []*notify.CardAlert
	err     error
}

func (p *trackerPusher) PushCard(_ context.Context, c notify.AlightCard, target notify.CardTarget, alert *notify.CardAlert) error {
	p.cards = append(p.cards, c)
	p.targets = append(p.targets, target)
	p.alerts = append(p.alerts, alert)
	return p.err
}

func trackerDependencies(t *testing.T) (*mrtTracker, *trackerStore, *trackerTrain, *trackerVibrator, *trackerPusher, *models.MrtTrackState, time.Time) {
	t.Helper()
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR required")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	if err := rc.Ping(context.Background()).Err(); err != nil {
		t.Fatal(err)
	}
	id := fmt.Sprintf("quality_mrt_%d_%d", os.Getpid(), time.Now().UnixNano())
	now := time.Unix(1_800_000_000, 0)
	state := mrtTestState(0, 4, 2, _mrtStatusTracking)
	state.TrackId = id
	state.NextPollAtUnix = now.Unix()
	state.LastProgressAtUnix = now.Add(-time.Minute).Unix()
	for i := range state.PathStationIds {
		state.PathStationIds[i] = fmt.Sprintf("BL%d_%s_%d", i, id, i)
	}
	paths := append([]string(nil), state.PathStationIds...)
	t.Cleanup(func() {
		keys := []string{shared.MrtTrackKey(id), shared.MrtTrackPushTokenKey(id)}
		for _, station := range paths {
			keys = append(keys, shared.MrtLiveKey("TRTC", station, "BL", paths[len(paths)-1]))
		}
		rc.Del(context.Background(), keys...)
	})
	store := &trackerStore{tracks: []notify.MrtTrackReminder{{ID: id, Token: "fcm"}}}
	train := &trackerTrain{found: true, info: &shared.TRTCTrainInfo{TripID: state.TripId, StnName: "c", CountdownTime: "00:30"}}
	vibrator := &trackerVibrator{}
	pusher := &trackerPusher{}
	return NewTracker(train, rc, store, vibrator, pusher), store, train, vibrator, pusher, state, now
}
func seedTrackerState(t *testing.T, rc *redis.Client, state *models.MrtTrackState) {
	t.Helper()
	raw, err := proto.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := rc.Set(context.Background(), shared.MrtTrackKey(state.TrackId), raw, time.Hour).Err(); err != nil {
		t.Fatal(err)
	}
}

func TestTrackerTickAdvancesVibratesPublishesAndPushes(t *testing.T) {
	tracker, store, _, vibrator, pusher, state, now := trackerDependencies(t)
	ctx := context.Background()
	seedTrackerState(t, tracker.rc, state)
	tracker.rc.Set(ctx, shared.MrtTrackPushTokenKey(state.TrackId), "activity", time.Hour)
	tracker.Tick(ctx, now)
	raw, err := tracker.rc.Get(ctx, shared.MrtTrackKey(state.TrackId)).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	next := &models.MrtTrackState{}
	if err := proto.Unmarshal(raw, next); err != nil {
		t.Fatal(err)
	}
	if next.CurrentIndex != 1 || next.RemainingStops != 3 || next.Status != _mrtStatusLeadFired || next.NextPollAtUnix != now.Add(40*time.Second).Unix() || next.LastProgressAtUnix != now.Unix() {
		t.Fatalf("advanced=%v", next)
	}
	want := notify.MrtVibrateEvent{ReminderID: state.TrackId + ":lead", Token: "fcm", TrackID: state.TrackId, AlightEvent: "lead"}
	if !reflect.DeepEqual(vibrator.events, []notify.MrtVibrateEvent{want}) {
		t.Fatalf("vibrations=%v", vibrator.events)
	}
	if len(pusher.cards) != 1 || pusher.cards[0].Phase != "approaching" || pusher.cards[0].RemainingStops != 3 || pusher.targets[0] != (notify.CardTarget{FCMToken: "fcm", ActivityToken: "activity"}) || pusher.alerts[0] == nil || pusher.alerts[0].Title != "Ready" {
		t.Fatalf("cards=%v targets=%v alerts=%v", pusher.cards, pusher.targets, pusher.alerts)
	}
	if len(store.expired) != 0 {
		t.Fatalf("live session expired=%v", store.expired)
	}
	tracker.Tick(ctx, now)
	if len(vibrator.events) != 1 || len(pusher.cards) != 1 {
		t.Fatal("future poll triggered duplicate work")
	}
}

func TestTrackerTickHandlesAbsentInvalidTerminalAndEndedSessions(t *testing.T) {
	tracker, store, train, vibrator, pusher, state, now := trackerDependencies(t)
	ctx := context.Background()
	tracker.Tick(ctx, now)
	if !reflect.DeepEqual(store.expired, []string{state.TrackId}) {
		t.Fatalf("missing expiry=%v", store.expired)
	}
	store.expired = nil
	tracker.rc.Set(ctx, shared.MrtTrackKey(state.TrackId), []byte{0xff}, time.Hour)
	tracker.Tick(ctx, now)
	if len(store.expired) != 0 {
		t.Fatal("malformed state expired reminder")
	}
	state.Status = _mrtStatusCancelled
	seedTrackerState(t, tracker.rc, state)
	tracker.Tick(ctx, now)
	if len(vibrator.events) != 0 {
		t.Fatal("terminal session polled")
	}
	state.Status = _mrtStatusTracking
	state.CurrentIndex = 3
	state.RemainingStops = 1
	train.info = &shared.TRTCTrainInfo{TripID: "changed", StnName: "offpath"}
	seedTrackerState(t, tracker.rc, state)
	vibrator.err = errors.New("push unavailable")
	pusher.err = errors.New("card unavailable")
	store.expireErr = errors.New("expiry unavailable")
	tracker.Tick(ctx, now)
	if len(store.expired) != 1 || len(vibrator.events) != 1 || vibrator.events[0].ReminderID != state.TrackId || vibrator.events[0].AlightEvent != "alight" {
		t.Fatalf("end expiry=%v vibrations=%v", store.expired, vibrator.events)
	}
	raw, err := tracker.rc.Get(ctx, shared.MrtTrackKey(state.TrackId)).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	next := &models.MrtTrackState{}
	if err := proto.Unmarshal(raw, next); err != nil {
		t.Fatal(err)
	}
	if next.Status != _mrtStatusArrived || next.NextPollAtUnix != 0 {
		t.Fatalf("ended=%v", next)
	}
	ttl := tracker.rc.TTL(ctx, shared.MrtTrackKey(state.TrackId)).Val()
	if ttl <= 0 || ttl > _mrtTrackEndedTTL {
		t.Fatalf("ended ttl=%v", ttl)
	}
	store.listErr = errors.New("list unavailable")
	tracker.Tick(ctx, now)
	store.listErr = nil
	store.tracks = nil
	tracker.Tick(ctx, now)
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	store.tracks = []notify.MrtTrackReminder{{ID: state.TrackId}}
	tracker.Tick(canceled, now)
}

func TestTrackerPositionClassifiesBindingsAndFallsBackToCachedLive(t *testing.T) {
	tracker, _, train, _, _, state, _ := trackerDependencies(t)
	ctx := context.Background()
	for _, tc := range []struct {
		trip, name, countdown string
		err                   error
		want                  mrtReading
	}{{state.TripId, "c", "00:30", nil, mrtReading{nextIndex: 2, countdown: 30 * time.Second, hasCountdown: true, gotInfo: true, resolved: true}}, {"wrong", "c", "", nil, mrtReading{lost: true}}, {state.TripId, "  ", "", nil, mrtReading{gotInfo: true}}, {state.TripId, "offpath", "", nil, mrtReading{lost: true}}, {state.TripId, "c", "bad", nil, mrtReading{nextIndex: 2, gotInfo: true, resolved: true}}, {"", "", "", errors.New("SOAP failed"), mrtReading{}}} {
		train.found = true
		train.info = &shared.TRTCTrainInfo{TripID: tc.trip, StnName: tc.name, CountdownTime: tc.countdown}
		train.err = tc.err
		if got := tracker.readPosition(ctx, state); !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("reading=%v want=%v", got, tc.want)
		}
	}
	train.found = false
	train.err = nil
	terminal := state.PathStationIds[len(state.PathStationIds)-1]
	key := func(i int) string { return shared.MrtLiveKey("TRTC", state.PathStationIds[i], "BL", terminal) }
	tracker.rc.Set(ctx, key(1), []byte{0xff}, time.Hour)
	raw, err := proto.Marshal(&models.MrtLive{TrainNumber: state.TripId})
	if err != nil {
		t.Fatal(err)
	}
	tracker.rc.Set(ctx, key(2), raw, time.Hour)
	if got := tracker.readPosition(ctx, state); !got.resolved || got.nextIndex != 2 || got.gotInfo {
		t.Fatalf("fallback=%v", got)
	}
	state.PathStationIds = nil
	if got := tracker.readPosition(ctx, state); got.resolved {
		t.Fatal("empty path resolved")
	}
}

func TestTrackerPushAndRedisFailuresLeaveStateRetryable(t *testing.T) {
	tracker, store, _, _, pusher, state, now := trackerDependencies(t)
	ctx := context.Background()
	tracker.pushCard(ctx, state, state, store.tracks[0], "", now)
	if len(pusher.cards) != 0 {
		t.Fatal("unchanged card pushed")
	}
	next := proto.Clone(state).(*models.MrtTrackState)
	next.CurrentIndex = 1
	tracker.pushCard(ctx, state, next, notify.MrtTrackReminder{ID: state.TrackId}, "", now)
	if len(pusher.cards) != 0 {
		t.Fatal("targetless card pushed")
	}
	tracker.pusher = nil
	tracker.pushCard(ctx, state, next, store.tracks[0], "", now)
	tracker.pusher = pusher
	closed := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = closed.Close()
	tracker.rc = closed
	if _, ok := tracker.readTrackState(ctx, state.TrackId); ok {
		t.Fatal("failed Redis read accepted")
	}
	if _, ok := tracker.fallbackFromLive(ctx, state); ok {
		t.Fatal("failed fallback read accepted")
	}
	tracker.publishState(ctx, state)
	tracker.pushCard(ctx, state, next, store.tracks[0], "", now)
	if len(pusher.cards) != 1 || pusher.targets[0].FCMToken != "fcm" {
		t.Fatal("Redis activity-token failure prevented FCM card")
	}
	state.VehicleLabel = string([]byte{0xff})
	tracker.publishState(ctx, state)
}
