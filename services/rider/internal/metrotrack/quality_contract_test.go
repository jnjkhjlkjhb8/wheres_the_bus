package metrotrack

import (
	"context"
	"errors"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestTrackPushTokenReportsAuthorizationAndRedisFailures(t *testing.T) {
	server, store, ctx := sessionDependencies(t)
	request := &pb.SetMrtTrackPushTokenRequest{InstallId: "install", TrackId: "quality_push_failure", PushToken: "abc"}
	store.authorized = false
	if _, err := server.SetTrackPushToken(ctx, request); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("unauthorized token: %v", err)
	}
	store.authorized = true
	if err := server.rc.Close(); err != nil {
		t.Fatal(err)
	}
	for _, token := range []string{"abc", ""} {
		request.PushToken = token
		if _, err := server.SetTrackPushToken(ctx, request); status.Code(err) != codes.Internal {
			t.Fatalf("Redis failure token %q: %v", token, err)
		}
	}
}

func TestCancelledTrackRetainsPublishedFieldsAndIgnoresMalformedState(t *testing.T) {
	server, _, ctx := sessionDependencies(t)
	const trackID = "quality_cancel_existing"
	key := shared.MrtTrackKey(trackID)
	t.Cleanup(func() { server.rc.Del(context.Background(), key) })
	initial := &pb.MrtTrackState{TrackId: trackID, System: "TRTC", TripId: "trip", CarId: "car", NextPollAtUnix: 100, PathStationIds: []string{"A", "B"}, TargetIndex: 1}
	if err := server.writeTrackState(ctx, initial, _mrtTrackSessionTTL); err != nil {
		t.Fatal(err)
	}
	server.publishCancelledState(ctx, trackID)
	got, err := decodeTrackState([]byte(server.rc.Get(ctx, key).Val()))
	if err != nil {
		t.Fatal(err)
	}
	initial.Status = "cancelled"
	initial.NextPollAtUnix = 0
	if !proto.Equal(got, initial) {
		t.Fatalf("cancelled state: %v", got)
	}
	if err := server.rc.Set(ctx, key, []byte{0xff}, _mrtTrackSessionTTL).Err(); err != nil {
		t.Fatal(err)
	}
	server.publishCancelledState(ctx, trackID)
	got, err = decodeTrackState([]byte(server.rc.Get(ctx, key).Val()))
	if err != nil || got.TrackId != trackID || got.System != "TRTC" || got.Status != "cancelled" {
		t.Fatalf("malformed fallback: %v %v", got, err)
	}
	if err := writeTrackState(ctx, server.rc, &pb.MrtTrackState{TrackId: string([]byte{0xff})}, _mrtTrackSessionTTL); err == nil {
		t.Fatal("invalid protobuf string accepted")
	}
}

func TestMetroSessionQueriesRejectInvalidDatabaseRows(t *testing.T) {
	server, _, ctx := sessionDependencies(t)
	if _, err := server.db.Exec(ctx, `ALTER TABLE mrt_adjacency ALTER COLUMN from_station_id DROP NOT NULL; INSERT INTO mrt_adjacency VALUES ('TRTC',NULL,'B')`); err != nil {
		t.Fatal(err)
	}
	if _, err := server.loadMrtAdjacency(ctx, "TRTC"); err == nil {
		t.Fatal("null adjacency accepted")
	}
	if _, err := server.db.Exec(ctx, `UPDATE mrt_station SET name=NULL WHERE station_id='A'`); err != nil {
		t.Fatal(err)
	}
	if _, err := server.mrtStationNames(ctx, []string{"A"}); err == nil {
		t.Fatal("null station name accepted")
	}
	rows, err := server.db.Query(ctx, `SELECT station_id,name FROM mrt_station WHERE 1/(length(station_id)-1)>0`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	if _, err = readMrtStationNames(rows); err == nil {
		t.Fatal("row iteration error ignored")
	}
	server.db.Close()
	if _, err := server.CreateTrack(ctx, sessionRequest()); status.Code(err) != codes.Internal {
		t.Fatalf("closed adjacency: %v", err)
	}
	if _, err := server.mrtStationNames(ctx, []string{"A"}); err == nil {
		t.Fatal("closed station query accepted")
	}
}

type leadFailureStore struct{ *sessionStore }

func (s leadFailureStore) CancelArrivalReminder(ctx context.Context, id, install string) (bool, error) {
	if id == mrtLeadReminderID("quality_lead_failure") {
		return false, errors.New("lead cancellation failed")
	}
	return s.sessionStore.CancelArrivalReminder(ctx, id, install)
}
func TestMetroCancellationKeepsMainSuccessWhenLeadRowFails(t *testing.T) {
	server, store, ctx := sessionDependencies(t)
	server.store = leadFailureStore{store}
	const trackID = "quality_lead_failure"
	t.Cleanup(func() { server.rc.Del(context.Background(), shared.MrtTrackKey(trackID)) })
	ack, err := server.CancelTrack(ctx, &pb.CancelMrtTrackRequest{InstallId: "install", TrackId: trackID})
	if err != nil || !ack.Ok {
		t.Fatalf("lead failure: %v %v", ack, err)
	}
}
