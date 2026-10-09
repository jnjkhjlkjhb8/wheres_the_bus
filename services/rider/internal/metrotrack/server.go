// Package metrotrack serves the MRT alight-tracking RPCs that write rider
// state: creating, cancelling and re-pointing a tracking session. WatchTrack
// only reads the session's Redis state, so api serves it directly.
package metrotrack

import (
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/redis/go-redis/v9"
	"google.golang.org/protobuf/proto"
)

type MrtServer struct {
	pb.UnimplementedMrt_ServiceServer

	rc    *redis.Client
	db    *pgxpool.Pool
	store mrtTrackStore
	trtc  mrtTrainInfo
	now   func() time.Time
}

func NewMrtServer(db *pgxpool.Pool, rc *redis.Client, store mrtTrackStore, trtc mrtTrainInfo, now func() time.Time) *MrtServer {
	return &MrtServer{db: db, rc: rc, store: store, trtc: trtc, now: now}
}

func decodeTrackState(raw []byte) (*pb.MrtTrackState, error) {
	state := &pb.MrtTrackState{}
	if err := proto.Unmarshal(raw, state); err != nil {
		return nil, err
	}
	return state, nil
}
