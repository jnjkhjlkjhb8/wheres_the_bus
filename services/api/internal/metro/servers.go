package metro

import (
	"context"
	"strings"
	"sync"

	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/riderfwd"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type MrtServer struct {
	pb.UnimplementedMrt_ServiceServer

	rc   *redis.Client
	db   *pgxpool.Pool
	live livestream.LiveSource
	// rider serves the tracking calls that write rider state.
	rider pb.Mrt_ServiceClient
}

// NewMrtServer wires the metro read path; tracking writes go to rider.
func NewMrtServer(db *pgxpool.Pool, rc *redis.Client, live livestream.LiveSource, rider pb.Mrt_ServiceClient) *MrtServer {
	return &MrtServer{db: db, rc: rc, live: live, rider: rider}
}

func (s *MrtServer) CreateTrack(ctx context.Context, in *pb.CreateMrtTrackRequest) (*pb.MrtTrackState, error) {
	return s.rider.CreateTrack(riderfwd.Outgoing(ctx), in)
}

func (s *MrtServer) CancelTrack(ctx context.Context, in *pb.CancelMrtTrackRequest) (*pb.MrtTrackAck, error) {
	return s.rider.CancelTrack(riderfwd.Outgoing(ctx), in)
}

func (s *MrtServer) SetTrackPushToken(ctx context.Context, in *pb.SetMrtTrackPushTokenRequest) (*pb.MrtTrackAck, error) {
	return s.rider.SetTrackPushToken(riderfwd.Outgoing(ctx), in)
}

// WatchTrack streams a session's state: it seeds from the current Redis state key
// then forwards each published update until the client disconnects -- the same
// seed-then-subscribe pattern as the metro arrival stream. It only reads, so it
// is served here rather than forwarded.
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

// Eta implements the Mrt_Service Eta streaming RPC by delegating to MrtEta.
func (s *MrtServer) Eta(in *pb.AskMrt, stream pb.Mrt_Service_EtaServer) error {
	return s.MrtEta(in, stream)
}

func (s *MrtServer) MrtEta(in *pb.AskMrt, stream pb.Mrt_Service_EtaServer) error {
	zap.S().Infow("call", "component", "grpc", "action", "mrt_eta", "event", "call", "system", in.System, "station_id", in.StationID)

	// stream.Send is not safe for concurrent use, so the per-station streams
	// serialize their sends through one mutex.
	var mu sync.Mutex
	send := func(data []byte) error {
		live, err := livestream.DecodePayload(data, &pb.MrtLive{})
		if err != nil {
			return err
		}
		mu.Lock()
		defer mu.Unlock()
		return stream.Send(&pb.Resp_MrtEta{Data: live})
	}

	g, ctx := errgroup.WithContext(stream.Context())
	for _, station := range strings.Split(in.StationID, "_") {
		if station == "" {
			continue
		}
		g.Go(func() error {
			return livestream.StreamLive(ctx, s.live, livestream.LiveStreamSpec{
				Channel:  shared.MrtLiveChannel(in.System, station),
				SeedScan: shared.MrtLiveSeedPattern(in.System, station),
			}, send)
		})
	}
	return g.Wait()
}
