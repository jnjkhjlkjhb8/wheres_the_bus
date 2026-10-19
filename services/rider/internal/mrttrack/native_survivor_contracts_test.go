package mrttrack

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/protobuf/proto"
)

func mrtContractReadState(t *testing.T, rc *redis.Client, id string) *models.MrtTrackState {
	t.Helper()
	raw, err := rc.Get(context.Background(), shared.MrtTrackKey(id)).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	state := &models.MrtTrackState{}
	if err := proto.Unmarshal(raw, state); err != nil {
		t.Fatal(err)
	}
	return state
}

func mrtContractLogs(t *testing.T) *observer.ObservedLogs {
	t.Helper()
	core, logs := observer.New(zap.DebugLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(undo)
	return logs
}

func mrtContractCause(t *testing.T, logs *observer.ObservedLogs, id, event string, cause error) {
	t.Helper()
	for _, entry := range logs.All() {
		fields := entry.ContextMap()
		if fields["track"] != id || fields["event"] != event {
			continue
		}
		for _, field := range entry.Context {
			if err, ok := field.Interface.(error); field.Key == "err" && ok && errors.Is(err, cause) {
				return
			}
		}
	}
	t.Fatalf("track=%s event=%s lost original cause %v: %+v", id, event, cause, logs.All())
}

func TestTrackerTickCrossingsMatchStoredProgressVibrationAndCard(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		target, lead, remaining int32
		fire, phase             string
	}{
		{"last-stop", 2, 1, 1, "alight", "approaching"},
		{"lead-boundary", 3, 1, 2, "lead", "approaching"},
		{"above-lead", 4, 1, 3, "", "riding"},
		{"lead-disabled", 3, 0, 2, "", "riding"},
		{"arrival", 1, 1, 0, "alight", "arrived"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tracker, store, _, vibrator, pusher, state, now := trackerDependencies(t)
			state.TargetIndex = tc.target
			state.LeadStops = tc.lead
			state.RemainingStops = tc.target
			seedTrackerState(t, tracker.rc, state)
			tracker.Tick(context.Background(), now)
			next := mrtContractReadState(t, tracker.rc, state.TrackId)
			if next.CurrentIndex != 1 || next.RemainingStops != tc.remaining || next.Progress != 1/float64(tc.target) {
				t.Fatalf("stored progress=%v", next)
			}
			if tc.fire == "" {
				if len(vibrator.events) != 0 {
					t.Fatalf("uncrossed vibration=%v", vibrator.events)
				}
			} else {
				if len(vibrator.events) != 1 || vibrator.events[0].AlightEvent != tc.fire || vibrator.events[0].TrackID != state.TrackId {
					t.Fatalf("crossing vibration=%v", vibrator.events)
				}
			}
			if len(pusher.cards) != 1 || pusher.cards[0].Phase != tc.phase || pusher.cards[0].RemainingStops != tc.remaining || pusher.cards[0].StaleAfter != 6*time.Minute {
				t.Fatalf("card crossing=%+v", pusher.cards)
			}
			if tc.fire == "" && pusher.alerts[0] != nil {
				t.Fatalf("uncrossed alert=%+v", pusher.alerts[0])
			}
			if tc.fire != "" {
				want := "Ready"
				if tc.fire == "alight" {
					want = "Get Set"
				}
				if pusher.alerts[0] == nil || pusher.alerts[0].Title != want {
					t.Fatalf("crossing alert=%+v", pusher.alerts[0])
				}
			}
			if tc.target == 1 {
				if next.Status != "arrived" || !reflect.DeepEqual(store.expired, []string{state.TrackId}) {
					t.Fatalf("arrival completion=%v expired=%v", next, store.expired)
				}
			} else {
				ttl, err := tracker.rc.PTTL(context.Background(), shared.MrtTrackKey(state.TrackId)).Result()
				if err != nil || ttl < 179*time.Minute || ttl > 3*time.Hour {
					t.Fatalf("active session TTL=%v err=%v", ttl, err)
				}
			}
		})
	}
}

func TestTrackerTickSameNextStationDoesNotResetProgressClock(t *testing.T) {
	tracker, _, train, _, _, state, now := trackerDependencies(t)
	train.info.StnName = "b"
	state.RemainingStops = state.TargetIndex
	seedTrackerState(t, tracker.rc, state)
	tracker.Tick(context.Background(), now)
	next := mrtContractReadState(t, tracker.rc, state.TrackId)
	if next.CurrentIndex != state.CurrentIndex || next.LastProgressAtUnix != state.LastProgressAtUnix {
		t.Fatalf("unchanged position reset progress clock: %v", next)
	}
}

func TestTrackerTickToleratesMissingTargetAndNextStationDisplayNames(t *testing.T) {
	for _, tc := range []struct {
		name              string
		names             []string
		target            int32
		station, nextName string
	}{
		{"missing-target", []string{"a", "b"}, 2, "b", "b"},
		{"missing-next", []string{"a"}, 4, "a", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tracker, _, train, _, pusher, state, now := trackerDependencies(t)
			state.PathStationNames = tc.names
			state.TargetIndex = tc.target
			state.RemainingStops = tc.target
			state.LeadStops = 0
			state.NextStationName = "old-display-name"
			train.info.StnName = tc.station
			seedTrackerState(t, tracker.rc, state)
			tracker.Tick(context.Background(), now)
			next := mrtContractReadState(t, tracker.rc, state.TrackId)
			if next.Status != "tracking" || next.CurrentIndex != 0 || next.NextStationName != tc.nextName || next.NextStationId != state.PathStationIds[1] {
				t.Fatalf("partial display-name progress=%v", next)
			}
			if len(pusher.cards) != 1 || pusher.cards[0].BoardStation != "a" || pusher.cards[0].TargetStation != "" || pusher.cards[0].NextStation != tc.nextName {
				t.Fatalf("partial display-name card=%+v", pusher.cards)
			}
		})
	}
}

func TestTrackerTickKeepsNeverProgressedAndExactTenMinuteSessionsLive(t *testing.T) {
	for _, tc := range []struct {
		name string
		zero bool
	}{{"never-progressed", true}, {"exact-ten-minutes", false}} {
		t.Run(tc.name, func(t *testing.T) {
			tracker, store, train, _, _, state, now := trackerDependencies(t)
			train.info.StnName = "b"
			state.RemainingStops = state.TargetIndex
			state.LastProgressAtUnix = 0
			if !tc.zero {
				state.LastProgressAtUnix = now.Add(-10 * time.Minute).Unix()
			}
			seedTrackerState(t, tracker.rc, state)
			tracker.Tick(context.Background(), now)
			next := mrtContractReadState(t, tracker.rc, state.TrackId)
			if next.Status != "tracking" || len(store.expired) != 0 || next.LastProgressAtUnix != state.LastProgressAtUnix || next.NextPollAtUnix <= now.Unix() {
				t.Fatalf("non-stale session ended: %v expired=%v", next, store.expired)
			}
		})
	}
}

func TestTrackerTickZeroCountdownUsesThirtySecondRetry(t *testing.T) {
	tracker, _, train, _, _, state, now := trackerDependencies(t)
	train.info.CountdownTime = "00:00"
	seedTrackerState(t, tracker.rc, state)
	tracker.Tick(context.Background(), now)
	next := mrtContractReadState(t, tracker.rc, state.TrackId)
	if next.NextPollAtUnix != now.Add(30*time.Second).Unix() {
		t.Fatalf("zero countdown poll=%d now=%d", next.NextPollAtUnix, now.Unix())
	}
}

func TestTrackerTickExpiryFaultsKeepOriginalCauseForMissingAndEndedStates(t *testing.T) {
	for _, missing := range []bool{true, false} {
		t.Run(fmt.Sprint(missing), func(t *testing.T) {
			tracker, store, _, _, _, state, now := trackerDependencies(t)
			logs := mrtContractLogs(t)
			cause := errors.New("track expiry unavailable")
			store.expireErr = cause
			if !missing {
				state.TargetIndex = 1
				state.RemainingStops = 1
				seedTrackerState(t, tracker.rc, state)
			}
			tracker.Tick(context.Background(), now)
			if !reflect.DeepEqual(store.expired, []string{state.TrackId}) {
				t.Fatalf("expiry attempts=%v", store.expired)
			}
			mrtContractCause(t, logs, state.TrackId, "expire_error", cause)
			if !missing {
				next := mrtContractReadState(t, tracker.rc, state.TrackId)
				if next.Status != "arrived" {
					t.Fatalf("expiry fault erased terminal state: %v", next)
				}
			}
		})
	}
}

func TestTrackerTickPushFaultsPreserveTerminalStateAndTruthfulDiagnostics(t *testing.T) {
	tracker, _, _, vibrator, pusher, state, now := trackerDependencies(t)
	logs := mrtContractLogs(t)
	vibrationCause := errors.New("vibration backend unavailable")
	pushCause := errors.New("card backend unavailable")
	vibrator.err = vibrationCause
	pusher.err = pushCause
	state.TargetIndex = 1
	state.RemainingStops = 1
	seedTrackerState(t, tracker.rc, state)
	tracker.Tick(context.Background(), now)
	mrtContractCause(t, logs, state.TrackId, "vibrate_error", vibrationCause)
	mrtContractCause(t, logs, state.TrackId, "push_error", pushCause)
	for _, entry := range logs.All() {
		if entry.ContextMap()["event"] == "vibrate_fired" || entry.ContextMap()["event"] == "pushed" {
			t.Fatalf("failed backend reported success: %+v", entry)
		}
	}
	next := mrtContractReadState(t, tracker.rc, state.TrackId)
	if next.Status != "arrived" || next.RemainingStops != 0 {
		t.Fatalf("push fault erased published arrival: %v", next)
	}
}

type mrtContractRedisFault struct {
	command   string
	cause     error
	published bool
}

func (*mrtContractRedisFault) DialHook(next redis.DialHook) redis.DialHook { return next }
func (*mrtContractRedisFault) ProcessPipelineHook(next redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return next
}
func (h *mrtContractRedisFault) ProcessHook(next redis.ProcessHook) redis.ProcessHook {
	return func(ctx context.Context, cmd redis.Cmder) error {
		if cmd.Name() == "publish" {
			h.published = true
		}
		if cmd.Name() == h.command {
			return h.cause
		}
		return next(ctx, cmd)
	}
}

func TestTrackerTickStateWriteFaultStopsPublicationAndKeepsPriorState(t *testing.T) {
	tracker, _, _, _, _, state, now := trackerDependencies(t)
	logs := mrtContractLogs(t)
	seedTrackerState(t, tracker.rc, state)
	cause := errors.New("owned Redis SET failed")
	hook := &mrtContractRedisFault{command: "set", cause: cause}
	tracker.rc.AddHook(hook)
	tracker.Tick(context.Background(), now)
	mrtContractCause(t, logs, state.TrackId, "set_error", cause)
	if hook.published {
		t.Fatal("failed state write published unsaved state")
	}
	next := mrtContractReadState(t, tracker.rc, state.TrackId)
	if !proto.Equal(next, state) {
		t.Fatalf("failed SET changed saved state: %v", next)
	}
}

func TestTrackerTickPublicationFaultKeepsSavedStateAndOriginalCause(t *testing.T) {
	tracker, _, _, _, _, state, now := trackerDependencies(t)
	logs := mrtContractLogs(t)
	seedTrackerState(t, tracker.rc, state)
	cause := errors.New("owned Redis PUBLISH failed")
	hook := &mrtContractRedisFault{command: "publish", cause: cause}
	tracker.rc.AddHook(hook)
	tracker.Tick(context.Background(), now)
	mrtContractCause(t, logs, state.TrackId, "publish_error", cause)
	if !hook.published {
		t.Fatal("state publication not attempted")
	}
	next := mrtContractReadState(t, tracker.rc, state.TrackId)
	if next.CurrentIndex != 1 || next.RemainingStops != 3 {
		t.Fatalf("publish fault erased persisted progress: %v", next)
	}
}
