package metro

import (
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"
)

type MrtServer struct {
	pb.UnimplementedMrt_ServiceServer

	rc    *redis.Client
	db    *pgxpool.Pool
	live  livestream.LiveSource
	store mrtTrackStore
	trtc  mrtTrainInfo
	now   func() time.Time
}

// NewMrtServer wires the metro read path and the reminder session store.
func NewMrtServer(db *pgxpool.Pool, rc *redis.Client, live livestream.LiveSource, store mrtTrackStore, trtc mrtTrainInfo, now func() time.Time) *MrtServer {
	return &MrtServer{db: db, rc: rc, live: live, store: store, trtc: trtc, now: now}
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
