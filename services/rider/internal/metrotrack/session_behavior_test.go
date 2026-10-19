package metrotrack

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/firebase"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type sessionStore struct {
	records       []firebase.FirebaseArrivalReminder
	cancellations [][2]string
	authorized    bool
	authErr       error
	createErr     error
	failAt        int
	cancelErr     error
	canceled      bool
}

func (s *sessionStore) AuthorizeInstall(context.Context, string, []byte) (bool, error) {
	return s.authorized, s.authErr
}
func (s *sessionStore) CreateArrivalReminder(_ context.Context, r firebase.FirebaseArrivalReminder) error {
	s.records = append(s.records, r)
	if s.failAt == len(s.records) {
		return s.createErr
	}
	return nil
}
func (s *sessionStore) CancelArrivalReminder(_ context.Context, id, install string) (bool, error) {
	s.cancellations = append(s.cancellations, [2]string{id, install})
	return s.canceled, s.cancelErr
}

type sessionTrainInfo struct {
	info  *shared.TRTCTrainInfo
	found bool
	err   error
}

func (f sessionTrainInfo) GetTrainInfo(context.Context, string) (*shared.TRTCTrainInfo, bool, error) {
	return f.info, f.found, f.err
}

func sessionDependencies(t *testing.T) (*MrtServer, *sessionStore, context.Context) {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	addr := os.Getenv("REDIS_TEST_ADDR")
	if dsn == "" || addr == "" {
		t.Skip("DATABASE_URL and REDIS_TEST_ADDR required")
	}
	admin, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("quality_metro_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(context.Background(), "CREATE SCHEMA "+quoted); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+quoted+" CASCADE"); admin.Close() })
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	db, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := db.Exec(context.Background(), `CREATE TABLE mrt_adjacency (system text,from_station_id text,to_station_id text); CREATE TABLE mrt_station (system text,station_id text,name text); INSERT INTO mrt_adjacency VALUES ('TRTC','A','B'),('TRTC','B','C'); INSERT INTO mrt_station VALUES ('TRTC','A','Alpha'),('TRTC','B','Beta'),('TRTC','C','Gamma')`); err != nil {
		t.Fatal(err)
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	if err := rc.Ping(context.Background()).Err(); err != nil {
		t.Fatal(err)
	}
	store := &sessionStore{authorized: true, canceled: true}
	at := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	server := NewMrtServer(db, rc, store, sessionTrainInfo{info: &shared.TRTCTrainInfo{TripID: "trip"}, found: true}, func() time.Time { return at })
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(installid.MetadataKey, "install", installid.SecretMetadataKey, strings.Repeat("s", 32)))
	return server, store, ctx
}
func sessionRequest() *pb.CreateMrtTrackRequest {
	return &pb.CreateMrtTrackRequest{InstallId: "install", CarId: "1021", BoardStationId: "A", DestStationId: "C", TargetStationId: "B", LeadStops: 1, System: "TRTC", VehicleLabel: "blue", LineCode: "BL", LineColorHex: "#0000FF"}
}

func TestCreateTrackPersistsLeadAndSeedsPublishedState(t *testing.T) {
	server, store, ctx := sessionDependencies(t)
	state, err := server.CreateTrack(ctx, sessionRequest())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { server.rc.Del(context.Background(), shared.MrtTrackKey(state.TrackId)) })
	if !validUUIDv4(state.TrackId) || state.TripId != "trip" || state.CarId != "1021" || !reflect.DeepEqual(state.PathStationIds, []string{"A", "B", "C"}) || !reflect.DeepEqual(state.PathStationNames, []string{"Alpha", "Beta", "Gamma"}) || state.TargetIndex != 1 || state.CurrentIndex != 0 || state.RemainingStops != 1 || state.NextStationId != "B" || state.NextStationName != "Beta" || state.Progress != 0 || state.Status != "tracking" || state.NextPollAtUnix != server.clock().Unix() || state.LastProgressAtUnix != server.clock().Unix() || state.LeadStops != 1 || state.LineCode != "BL" || state.LineColorHex != "#0000FF" || state.VehicleLabel != "blue" {
		t.Fatalf("state=%v", state)
	}
	if len(store.records) != 2 {
		t.Fatalf("records=%v", store.records)
	}
	base := store.records[0]
	lead := store.records[1]
	if base.ReminderID != state.TrackId || base.RouteType != "mrt" || base.RouteKey != "trip" || base.StopKey != "B" || base.Direction != "C" || base.LeadMinutes != 1 || base.Plate != "1021" || base.AlightEvent != "alight" || !base.ExpiresAt.Equal(server.clock().Add(3*time.Hour)) || base.Status != firebase.ReminderPending {
		t.Fatalf("base=%v", base)
	}
	base.ReminderID = mrtLeadReminderID(state.TrackId)
	base.AlightEvent = "lead"
	if !reflect.DeepEqual(base, lead) {
		t.Fatalf("lead=%v want=%v", lead, base)
	}
	raw, err := server.rc.Get(ctx, shared.MrtTrackKey(state.TrackId)).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	stored, err := decodeTrackState(raw)
	if err != nil || !proto.Equal(stored, state) {
		t.Fatalf("stored=%v %v", stored, err)
	}
	ttl := server.rc.TTL(ctx, shared.MrtTrackKey(state.TrackId)).Val()
	if ttl < 3*time.Hour-time.Minute || ttl > 3*time.Hour {
		t.Fatalf("ttl=%v", ttl)
	}
	req := sessionRequest()
	req.LeadStops = 0
	store.records = nil
	state, err = server.CreateTrack(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	defer server.rc.Del(ctx, shared.MrtTrackKey(state.TrackId))
	if len(store.records) != 1 || store.records[0].LeadMinutes != 1 || state.LeadStops != 0 {
		t.Fatalf("no lead=%v %v", state, store.records)
	}
}

func TestCreateTrackErrorsPreserveContractsAndLeadRollback(t *testing.T) {
	server, store, ctx := sessionDependencies(t)
	for _, tc := range []struct {
		err  error
		code codes.Code
	}{{firebase.ErrReminderLimitReached, codes.ResourceExhausted}, {firebase.ErrReminderDuplicate, codes.AlreadyExists}, {errors.New("write failed"), codes.Internal}} {
		for _, failAt := range []int{1, 2} {
			store.records = nil
			store.cancellations = nil
			store.failAt = failAt
			store.createErr = tc.err
			if _, err := server.CreateTrack(ctx, sessionRequest()); status.Code(err) != tc.code {
				t.Fatalf("fail %d=%v", failAt, err)
			}
			wantCancel := failAt - 1
			if len(store.cancellations) != wantCancel {
				t.Fatalf("rollback=%v", store.cancellations)
			}
			if wantCancel == 1 && store.cancellations[0] != [2]string{store.records[0].ReminderID, "install"} {
				t.Fatalf("rollback identity=%v", store.cancellations)
			}
		}
	}
	store.failAt = 0
	store.authorized = false
	if _, err := server.CreateTrack(ctx, sessionRequest()); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("authorization=%v", err)
	}
	store.authErr = errors.New("lookup failed")
	if _, err := server.CreateTrack(ctx, sessionRequest()); status.Code(err) != codes.Internal {
		t.Fatalf("auth store=%v", err)
	}
	store.authErr = nil
	store.authorized = true
	server.trtc = sessionTrainInfo{}
	if _, err := server.CreateTrack(ctx, sessionRequest()); status.Code(err) != codes.NotFound {
		t.Fatalf("car miss=%v", err)
	}
	server.trtc = sessionTrainInfo{err: errors.New("SOAP failed")}
	if _, err := server.CreateTrack(ctx, sessionRequest()); status.Code(err) != codes.Internal {
		t.Fatalf("SOAP=%v", err)
	}
	req := sessionRequest()
	req.DestStationId = "missing"
	if _, err := server.CreateTrack(ctx, req); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("path=%v", err)
	}
	req = sessionRequest()
	req.TargetStationId = "A"
	if _, err := server.CreateTrack(ctx, req); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("target=%v", err)
	}
}

func TestSessionCancelAndPushTokenOperations(t *testing.T) {
	server, store, ctx := sessionDependencies(t)
	track := fmt.Sprintf("quality_track_%d_%d", os.Getpid(), time.Now().UnixNano())
	key := shared.MrtTrackPushTokenKey(track)
	t.Cleanup(func() { server.rc.Del(context.Background(), key, shared.MrtTrackKey(track)) })
	ack, err := server.SetTrackPushToken(ctx, &pb.SetMrtTrackPushTokenRequest{InstallId: "install", TrackId: track, PushToken: "abcDEF"})
	if err != nil || !ack.Ok {
		t.Fatalf("token=%v %v", ack, err)
	}
	if server.rc.Get(ctx, key).Val() != "abcDEF" {
		t.Fatal("token absent")
	}
	ack, err = server.SetTrackPushToken(ctx, &pb.SetMrtTrackPushTokenRequest{InstallId: "install", TrackId: track})
	if err != nil || !ack.Ok || server.rc.Exists(ctx, key).Val() != 0 {
		t.Fatalf("clear=%v %v", ack, err)
	}
	ack, err = server.CancelTrack(ctx, &pb.CancelMrtTrackRequest{InstallId: "install", TrackId: track})
	if err != nil || !ack.Ok {
		t.Fatalf("cancel=%v %v", ack, err)
	}
	if !reflect.DeepEqual(store.cancellations, [][2]string{{track, "install"}, {mrtLeadReminderID(track), "install"}}) {
		t.Fatalf("cancellations=%v", store.cancellations)
	}
	raw, err := server.rc.Get(ctx, shared.MrtTrackKey(track)).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeTrackState(raw)
	if err != nil || state.Status != "cancelled" || state.NextPollAtUnix != 0 {
		t.Fatalf("cancelled=%v %v", state, err)
	}
	store.canceled = false
	if _, err := server.CancelTrack(ctx, &pb.CancelMrtTrackRequest{InstallId: "install", TrackId: track}); status.Code(err) != codes.NotFound {
		t.Fatalf("missing cancel=%v", err)
	}
	store.cancelErr = errors.New("cancel failed")
	if _, err := server.CancelTrack(ctx, &pb.CancelMrtTrackRequest{InstallId: "install", TrackId: track}); status.Code(err) != codes.Internal {
		t.Fatalf("failed cancel=%v", err)
	}
}

func TestTrackRequestBoundaryValues(t *testing.T) {
	for _, n := range []int32{0, 120} {
		req := sessionRequest()
		req.LeadStops = n
		req.VehicleLabel = strings.Repeat("a", 64)
		req.LineCode = strings.Repeat("b", 8)
		if err := validateTrackRequest(req); err != nil {
			t.Fatal(err)
		}
	}
	for _, field := range []string{"install", "car", "board", "dest", "target", "line"} {
		req := sessionRequest()
		switch field {
		case "install":
			req.InstallId = ""
		case "car":
			req.CarId = ""
		case "board":
			req.BoardStationId = ""
		case "dest":
			req.DestStationId = ""
		case "target":
			req.TargetStationId = ""
		case "line":
			req.LineCode = strings.Repeat("b", 9)
		}
		if status.Code(validateTrackRequest(req)) != codes.InvalidArgument {
			t.Fatalf("invalid %s accepted", field)
		}
	}
	for _, tc := range []struct {
		path, names []string
		id, name    string
	}{{nil, nil, "", ""}, {[]string{"A"}, []string{"Alpha"}, "", ""}, {[]string{"A", "B"}, nil, "B", ""}, {[]string{"A", "B"}, []string{"Alpha", "Beta"}, "B", "Beta"}} {
		id, name := nextTrackStation(tc.path, tc.names)
		if id != tc.id || name != tc.name {
			t.Fatalf("next=%q,%q", id, name)
		}
	}
}
