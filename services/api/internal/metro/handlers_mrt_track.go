package metro

import (
	"context"
	"errors"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/firebase"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/installid"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// mrtTrackStore is the reminder-persistence surface the session RPCs need,
// satisfied by *firebaseStore. It is the same firebase_arrival_reminder table
// bus and rail reminders use, reused for metro sessions (route_type='mrt').
type mrtTrackStore interface {
	AuthorizeInstall(context.Context, string, []byte) (bool, error)
	CreateArrivalReminder(context.Context, firebase.FirebaseArrivalReminder) error
	CancelArrivalReminder(context.Context, string, string) (bool, error)
}

// mrtTrainInfo is the GetTrainInfo seam used to verify a car binding at session
// creation, satisfied by *shared.TRTCTrainInfoClient and stubbed in tests.
type mrtTrainInfo interface {
	GetTrainInfo(ctx context.Context, carID string) (*shared.TRTCTrainInfo, bool, error)
}

func mrtLeadReminderID(trackID string) string { return trackID + ":lead" }

// _mrtTrackSessionTTL keeps a session's reminder row and Redis state alive for a
// generous single ride; the functions tracker ends most sessions well before it.
const _mrtTrackSessionTTL = 3 * time.Hour

// _mrtTrackEndedStateTTL keeps a cancelled session's final state briefly so a
// connected watcher receives the ending before the key disappears.
const _mrtTrackEndedStateTTL = 60 * time.Second

func (s *MrtServer) CreateTrack(ctx context.Context, request *pb.CreateMrtTrackRequest) (*pb.MrtTrackState, error) {
	if !installid.ValidText(request.GetInstallId(), 128) || !installid.ValidText(request.GetCarId(), 32) ||
		!installid.ValidText(request.GetBoardStationId(), 32) || !installid.ValidText(request.GetDestStationId(), 32) ||
		!installid.ValidText(request.GetTargetStationId(), 32) {
		return nil, status.Error(codes.InvalidArgument, "install_id, car_id, and station IDs are required")
	}
	if request.System != "TRTC" {
		return nil, status.Error(codes.FailedPrecondition, "metro alight reminders are supported for TRTC only")
	}
	if request.LeadStops < 0 || request.LeadStops > 120 {
		return nil, status.Error(codes.InvalidArgument, "lead_stops must be between 0 and 120")
	}
	if len(request.VehicleLabel) > 64 || len(request.LineCode) > 8 || !validHexColor(request.LineColorHex) {
		return nil, status.Error(codes.InvalidArgument, "invalid card display fields")
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}

	adjacency, err := s.loadMrtAdjacency(ctx, "TRTC")
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "mrt_track",
			"action", "create",
			"event", "load_adjacency_failed",
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to load metro adjacency")
	}
	path, ok := mrtBFSPath(adjacency, request.BoardStationId, request.DestStationId)
	if !ok {
		return nil, status.Error(codes.InvalidArgument, "這班車不到該站")
	}
	targetIndex, ok := mrtTargetIndex(path, request.TargetStationId)
	if !ok {
		return nil, status.Error(codes.InvalidArgument, "這班車不到該站")
	}

	info, found, err := s.trtc.GetTrainInfo(ctx, request.CarId)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "mrt_track",
			"action", "create",
			"event", "get_train_info_failed",
			"car", request.CarId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to verify car binding")
	}
	if !found {
		return nil, status.Error(codes.NotFound, "查無此車")
	}

	names, err := s.mrtStationNames(ctx, path)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "mrt_track",
			"action", "create",
			"event", "load_station_names_failed",
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to load station names")
	}

	trackID, err := installid.NewUUIDv4()
	if err != nil {
		zap.S().Errorw("uuid generation failed",
			"component", "mrt_track",
			"action", "create",
			"event", "uuid_failed",
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to create session ID")
	}
	now := s.clock()
	expiresAt := now.Add(_mrtTrackSessionTTL)
	storedLead := max(request.LeadStops, 1)
	stored := firebase.FirebaseArrivalReminder{
		ReminderID: trackID, InstallID: request.InstallId, RouteType: "mrt", RouteKey: info.TripID,
		StopKey: request.TargetStationId, Direction: request.DestStationId, LeadMinutes: storedLead,
		ExpiresAt: expiresAt, Status: firebase.ReminderPending, Plate: request.CarId,
		AlightEvent: "alight",
	}
	if err := s.store.CreateArrivalReminder(ctx, stored); err != nil {
		zap.S().Errorw("store failed",
			"component", "mrt_track",
			"action", "create",
			"event", "save_session_failed",
			"track", trackID,
			"err", err,
		)
		if errors.Is(err, firebase.ErrReminderLimitReached) {
			return nil, status.Error(codes.ResourceExhausted, "too many active arrival reminders")
		}
		if errors.Is(err, firebase.ErrReminderDuplicate) {
			return nil, status.Error(codes.AlreadyExists, "arrival reminder already exists")
		}
		return nil, status.Error(codes.Internal, "failed to save metro session")
	}
	if request.LeadStops > 0 {
		lead := stored
		lead.ReminderID = mrtLeadReminderID(trackID)
		lead.AlightEvent = "lead"
		if err := s.store.CreateArrivalReminder(ctx, lead); err != nil {
			_, _ = s.store.CancelArrivalReminder(ctx, stored.ReminderID, request.InstallId)
			zap.S().Errorw("store failed",
				"component", "mrt_track",
				"action", "create",
				"event", "save_lead_session_failed",
				"track", trackID,
				"err", err,
			)
			if errors.Is(err, firebase.ErrReminderLimitReached) {
				return nil, status.Error(codes.ResourceExhausted, "too many active arrival reminders")
			}
			if errors.Is(err, firebase.ErrReminderDuplicate) {
				return nil, status.Error(codes.AlreadyExists, "arrival reminder already exists")
			}
			return nil, status.Error(codes.Internal, "failed to save metro session")
		}
	}

	nextStationID, nextStationName := "", ""
	if len(path) > 1 {
		nextStationID = path[1]
		if len(names) > 1 {
			nextStationName = names[1]
		}
	}
	state := &pb.MrtTrackState{
		TrackId: trackID, TripId: info.TripID, CarId: request.CarId,
		PathStationIds: path, PathStationNames: names,
		TargetIndex: targetIndex, CurrentIndex: 0, RemainingStops: targetIndex,
		NextStationId: nextStationID, NextStationName: nextStationName, Progress: 0,
		Status: "tracking", NextPollAtUnix: now.Unix(), LeadStops: request.LeadStops,
		System: "TRTC",
		// Seed the stale clock at creation: a session whose binding never advances
		// at all must still end after the stale window, not poll until expires_at.
		LastProgressAtUnix: now.Unix(),
		VehicleLabel:       request.VehicleLabel,
		LineCode:           request.LineCode,
		LineColorHex:       request.LineColorHex,
	}
	if err := s.writeTrackState(ctx, state, _mrtTrackSessionTTL); err != nil {
		zap.S().Errorw("store failed",
			"component", "mrt_track",
			"action", "create",
			"event", "seed_state_failed",
			"track", trackID,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to seed metro session state")
	}
	zap.S().Infow("log",
		"component", "mrt_track",
		"action", "create",
		"track", trackID,
		"trip", info.TripID,
		"car", request.CarId,
		"target_index", targetIndex,
	)
	return state, nil
}

// WatchTrack streams a session's state: it seeds from the current Redis state key
// then forwards each published update until the client disconnects — the same
// seed-then-subscribe pattern as the metro arrival stream.
func (s *MrtServer) WatchTrack(request *pb.WatchMrtTrackRequest, stream pb.Mrt_Service_WatchTrackServer) error {
	if !installid.ValidText(request.GetTrackId(), 64) {
		return status.Error(codes.InvalidArgument, "track_id is required")
	}
	send := func(data []byte) error {
		state, err := livestream.DecodePayload(data, &pb.MrtTrackState{})
		if err != nil {
			return err
		}
		return stream.Send(state)
	}
	return livestream.StreamLive(stream.Context(), s.live, livestream.LiveStreamSpec{
		Channel:  shared.MrtTrackChannel(request.TrackId),
		SeedKeys: []string{shared.MrtTrackKey(request.TrackId)},
	}, send)
}

func (s *MrtServer) CancelTrack(ctx context.Context, request *pb.CancelMrtTrackRequest) (*pb.MrtTrackAck, error) {
	if !installid.ValidText(request.GetInstallId(), 128) || !installid.ValidText(request.GetTrackId(), 64) {
		return nil, status.Error(codes.InvalidArgument, "install_id and track_id are required")
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	cancelled, err := s.store.CancelArrivalReminder(ctx, request.TrackId, request.InstallId)
	if err != nil {
		zap.S().Errorw("store failed",
			"component", "mrt_track",
			"action", "cancel",
			"event", "cancel_failed",
			"track", request.TrackId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to cancel metro session")
	}
	if !cancelled {
		return nil, status.Error(codes.NotFound, "metro session not found")
	}
	if _, leadErr := s.store.CancelArrivalReminder(ctx, mrtLeadReminderID(request.TrackId), request.InstallId); leadErr != nil {
		zap.S().Warnw("lead row error",
			"component", "mrt_track",
			"action", "cancel",
			"event", "lead_row_error",
			"track", request.TrackId,
			"err", leadErr,
		)
	}
	s.publishCancelledState(ctx, request.TrackId)
	return &pb.MrtTrackAck{Ok: true}, nil
}

func (s *MrtServer) SetTrackPushToken(ctx context.Context, request *pb.SetMrtTrackPushTokenRequest) (*pb.MrtTrackAck, error) {
	if !installid.ValidText(request.GetInstallId(), 128) || !installid.ValidText(request.GetTrackId(), 64) {
		return nil, status.Error(codes.InvalidArgument, "install_id and track_id are required")
	}
	// APNs tokens are lowercase hex; anything else never reaches Apple, so it is
	// rejected at the door rather than stored and retried every station hop.
	if !validPushToken(request.GetPushToken()) {
		return nil, status.Error(codes.InvalidArgument, "push_token must be hex")
	}
	if err := s.authorizeInstall(ctx, request.InstallId); err != nil {
		return nil, err
	}
	key := shared.MrtTrackPushTokenKey(request.TrackId)
	if request.PushToken == "" {
		if err := s.rc.Del(ctx, key).Err(); err != nil {
			zap.S().Errorw("store failed",
				"component", "mrt_track",
				"action", "set_push_token",
				"event", "del_failed",
				"track", request.TrackId,
				"err", err,
			)
			return nil, status.Error(codes.Internal, "failed to store push token")
		}
		return &pb.MrtTrackAck{Ok: true}, nil
	}
	if err := s.rc.Set(ctx, key, request.PushToken, _mrtTrackSessionTTL).Err(); err != nil {
		zap.S().Errorw("store failed",
			"component", "mrt_track",
			"action", "set_push_token",
			"event", "set_failed",
			"track", request.TrackId,
			"err", err,
		)
		return nil, status.Error(codes.Internal, "failed to store push token")
	}
	return &pb.MrtTrackAck{Ok: true}, nil
}

// validHexColor accepts an empty value or `#RRGGBB`, the form the app's line
// colour table produces.
func validHexColor(value string) bool {
	if value == "" {
		return true
	}
	if len(value) != 7 || value[0] != '#' {
		return false
	}
	for _, r := range value[1:] {
		if !isHexDigit(r) {
			return false
		}
	}
	return true
}

// validPushToken accepts an empty value (the clear) or a bounded hex string.
func validPushToken(value string) bool {
	if len(value) > 256 {
		return false
	}
	for _, r := range value {
		if !isHexDigit(r) {
			return false
		}
	}
	return true
}

func isHexDigit(r rune) bool {
	return (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
}

func (s *MrtServer) publishCancelledState(ctx context.Context, trackID string) {
	publishCancelledTrackState(ctx, s.rc, trackID)
}

func publishCancelledTrackState(ctx context.Context, rc *redis.Client, trackID string) {
	state := &pb.MrtTrackState{TrackId: trackID, System: "TRTC"}
	if raw, err := rc.Get(ctx, shared.MrtTrackKey(trackID)).Bytes(); err == nil {
		if decoded, decodeErr := livestream.DecodePayload(raw, &pb.MrtTrackState{}); decodeErr == nil {
			state = decoded
		}
	}
	state.Status = "cancelled"
	state.NextPollAtUnix = 0
	if err := writeTrackState(ctx, rc, state, _mrtTrackEndedStateTTL); err != nil {
		zap.S().Warnw("publish error",
			"component", "mrt_track",
			"action", "cancel",
			"event", "publish_error",
			"track", trackID,
			"err", err,
		)
	}
}

func (s *MrtServer) writeTrackState(ctx context.Context, state *pb.MrtTrackState, ttl time.Duration) error {
	return writeTrackState(ctx, s.rc, state, ttl)
}

// writeTrackState marshals a state, stores it under MrtTrackKey with ttl, and
// publishes it on MrtTrackChannel so any established watcher receives it.
func writeTrackState(ctx context.Context, rc *redis.Client, state *pb.MrtTrackState, ttl time.Duration) error {
	payload, err := proto.Marshal(state)
	if err != nil {
		return err
	}
	if err := rc.Set(ctx, shared.MrtTrackKey(state.TrackId), payload, ttl).Err(); err != nil {
		return err
	}
	return rc.Publish(ctx, shared.MrtTrackChannel(state.TrackId), payload).Err()
}

// clock returns the server's now function, defaulting to time.Now when unset so
// tests can pin the session clock.
func (s *MrtServer) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

// authorizeInstall verifies the caller owns the installation, reusing the
// install-secret machinery the Firebase reminder RPCs use.
func (s *MrtServer) authorizeInstall(ctx context.Context, installID string) error {
	secretHash, err := installid.SecretHash(ctx, installID)
	if err != nil {
		return err
	}
	authorized, err := s.store.AuthorizeInstall(ctx, installID, secretHash)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "mrt_track",
			"action", "authorize_install",
			"event", "query_failed",
			"err", err,
		)
		return status.Error(codes.Internal, "failed to verify installation credential")
	}
	if !authorized {
		// A device that never completed upsertDevice has no row to match, which
		// is the same silent PermissionDenied as a rotated secret. Naming it here
		// is what separates the two without a database round trip.
		zap.S().Warnw("install unauthorized",
			"component", "mrt_track",
			"action", "authorize_install",
			"event", "install_unauthorized",
			"install", installID,
		)
		return status.Error(codes.PermissionDenied, "installation credential does not match")
	}
	return nil
}

func (s *MrtServer) loadMrtAdjacency(ctx context.Context, system string) (map[string][]string, error) {
	rows, err := s.db.Query(ctx, `SELECT from_station_id, to_station_id FROM mrt_adjacency WHERE system = $1`, system)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	adjacency := make(map[string][]string)
	for rows.Next() {
		var from, to string
		if err := rows.Scan(&from, &to); err != nil {
			return nil, err
		}
		adjacency[from] = append(adjacency[from], to)
	}
	return adjacency, rows.Err()
}

// mrtStationNames returns the display names for the path stations in path order,
// leaving an unmatched station's name empty rather than failing the session.
func (s *MrtServer) mrtStationNames(ctx context.Context, path []string) ([]string, error) {
	rows, err := s.db.Query(ctx, `SELECT station_id, name FROM mrt_station WHERE system = 'TRTC' AND station_id = ANY($1)`, path)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byID := make(map[string]string)
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		byID[id] = name
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	names := make([]string, len(path))
	for i, id := range path {
		names[i] = byID[id]
	}
	return names, nil
}

func mrtBFSPath(adjacency map[string][]string, board, terminal string) ([]string, bool) {
	if board == terminal {
		return nil, false
	}
	prev := map[string]string{board: ""}
	queue := []string{board}
	for len(queue) > 0 {
		node := queue[0]
		queue = queue[1:]
		if node == terminal {
			return mrtReconstruct(prev, terminal), true
		}
		for _, next := range adjacency[node] {
			if _, seen := prev[next]; seen {
				continue
			}
			prev[next] = node
			queue = append(queue, next)
		}
	}
	return nil, false
}

// mrtReconstruct walks the BFS predecessor map from terminal back to the root and
// returns the path in board→terminal order.
func mrtReconstruct(prev map[string]string, terminal string) []string {
	var reversed []string
	for node := terminal; node != ""; node = prev[node] {
		reversed = append(reversed, node)
	}
	path := make([]string, len(reversed))
	for i, node := range reversed {
		path[len(reversed)-1-i] = node
	}
	return path
}

// mrtTargetIndex returns the target station's position on the path. ok is false
// when the target is not strictly ahead of the board (index 0) — i.e. absent
// from the path or the board itself — which is the "這班車不到該站" rejection.
func mrtTargetIndex(path []string, target string) (int32, bool) {
	for i, station := range path {
		if station == target {
			if i == 0 {
				return 0, false
			}
			return int32(i), true
		}
	}
	return 0, false
}
