package transit

import (
	"bytes"
	"context"
	"slices"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const (
	_nearbyEtaMaxGroups = 10
	_nearbyEtaPerGroup  = 3
	_nearbyEtaInterval  = 15 * time.Second
	// Same demand window as the single-group eta stream (livestream).
	_nearbyEtaDemandTTL = 10 * time.Minute
)

// Etas implements the Bus_Station_Service Etas streaming RPC: the home list's
// groups in one stream, polled from the station ETA keys rather than
// subscribed, so it takes no live-hub subscription per group.
func (s *BusStationserver) Etas(in *pb.Bus_Ask_StationGroups, stream pb.Bus_Station_Service_EtasServer) error {
	return streamNearbyEtas(stream.Context(), s.live, in.Groups, _nearbyEtaInterval, stream.Send)
}

func streamNearbyEtas(ctx context.Context, live livestream.LiveSource, asked []*pb.Bus_Ask_StationGroup, every time.Duration, send func(*pb.Resp_BusStationEtas) error) error {
	groups := nearbyEtaGroups(asked)
	if len(groups) == 0 {
		return status.Error(codes.InvalidArgument, "etas needs at least one group with city and group_uid")
	}
	poll := time.NewTicker(every)
	defer poll.Stop()
	return pollNearbyEtas(ctx, live, groups, poll.C, send)
}

func pollNearbyEtas(ctx context.Context, live livestream.LiveSource, groups []*pb.Bus_Ask_StationGroup, poll <-chan time.Time, send func(*pb.Resp_BusStationEtas) error) error {
	var last []byte
	for {
		// Demand is renewed on every poll, not on changes: a city whose data
		// stops changing would otherwise lapse and stop being fetched. Touch
		// never shortens a longer TTL, so renewing often costs one write.
		touchNearbyEtaDemand(ctx, live, groups)
		if err := sendNearbyEtaIfChanged(ctx, live, groups, &last, send); err != nil {
			return err
		}
		if err := waitNearbyEtaPoll(ctx, poll); err != nil {
			return err
		}
	}
}

func waitNearbyEtaPoll(ctx context.Context, poll <-chan time.Time) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-poll:
		return nil
	}
}

func nearbyEtaGroups(asked []*pb.Bus_Ask_StationGroup) []*pb.Bus_Ask_StationGroup {
	groups := make([]*pb.Bus_Ask_StationGroup, 0, min(len(asked), _nearbyEtaMaxGroups))
	for _, g := range asked {
		if len(groups) == _nearbyEtaMaxGroups {
			break
		}
		if askedGroupComplete(g) {
			groups = append(groups, g)
		}
	}
	return groups
}

func askedGroupComplete(g *pb.Bus_Ask_StationGroup) bool {
	return g.City != "" && g.GroupUid != ""
}

func touchNearbyEtaDemand(ctx context.Context, live livestream.LiveSource, groups []*pb.Bus_Ask_StationGroup) {
	seen := make(map[string]bool, len(groups))
	for _, g := range groups {
		if !seen[g.City] {
			seen[g.City] = true
			live.Touch(ctx, busEtaDemandKey(g.City), _nearbyEtaDemandTTL)
		}
	}
}

func sendNearbyEtaIfChanged(ctx context.Context, live livestream.LiveSource, groups []*pb.Bus_Ask_StationGroup, last *[]byte, send func(*pb.Resp_BusStationEtas) error) error {
	frame := nearbyEtaFrame(ctx, live, groups, time.Now())
	// Deterministic, or map order alone would make every frame look new.
	data, err := proto.MarshalOptions{Deterministic: true}.Marshal(frame)
	if err != nil || bytes.Equal(data, *last) {
		return err
	}
	*last = data
	return send(frame)
}

// nearbyEtaFrame holds one entry per group with usable data; a group not yet
// fetched is left out rather than failing the frame. It reads one key per
// group (at most 10 a poll); an MGET on LiveSource is the step up if Redis
// round trips ever show in the latency.
func nearbyEtaFrame(ctx context.Context, live livestream.LiveSource, groups []*pb.Bus_Ask_StationGroup, now time.Time) *pb.Resp_BusStationEtas {
	frame := &pb.Resp_BusStationEtas{Groups: make(map[string]*pb.Bus_StationArrival, len(groups))}
	for _, g := range groups {
		if arrival, ok := nearbyGroupArrival(ctx, live, g, now); ok {
			frame.Groups[g.GroupUid] = arrival
		}
	}
	return frame
}

func nearbyGroupArrival(ctx context.Context, live livestream.LiveSource, g *pb.Bus_Ask_StationGroup, now time.Time) (*pb.Bus_StationArrival, bool) {
	data, ok := live.Get(ctx, shared.BusStationEtaKey(g.City, g.GroupUid))
	if !ok || !usableBusEtaPayload(data) {
		return nil, false
	}
	arrival, err := livestream.DecodePayload(data, &pb.Bus_StationArrival{})
	if err != nil {
		return nil, false
	}
	arrival.Routes = soonestNearbyRoutes(arrival.Routes, now)
	return arrival, true
}

// soonestNearbyRoutes keeps the few routes coming soonest, a superset of the
// two the client ranks with its own rules. Times are left as sent, so a frame
// changes only when the data does; vehicle positions are dropped as the bulk
// of the payload.
func soonestNearbyRoutes(routes []*pb.Bus_StopEstimate, now time.Time) []*pb.Bus_StopEstimate {
	timed := make([]*pb.Bus_StopEstimate, 0, len(routes))
	for _, r := range routes {
		if nearbyEtaRemaining(r, now) >= 0 {
			r.Buses = nil
			timed = append(timed, r)
		}
	}
	slices.SortStableFunc(timed, func(a, b *pb.Bus_StopEstimate) int {
		return int(nearbyEtaRemaining(a, now) - nearbyEtaRemaining(b, now))
	})
	return timed[:min(len(timed), _nearbyEtaPerGroup)]
}

// nearbyEtaRemaining is the seconds until the bus comes, or negative when the
// estimate holds no time: a service state such as 末班駛離, or a
// not-yet-departed bus whose time is only a clock string.
func nearbyEtaRemaining(r *pb.Bus_StopEstimate, now time.Time) int64 {
	if r.ArrivalUnix > 0 {
		return max(r.ArrivalUnix-now.Unix(), 0)
	}
	return nearbyEstimateSeconds(r)
}

// nearbyEstimateSeconds reads the server estimate: 0 with a normal status is
// 進站中; any other non-positive estimate carries no time.
func nearbyEstimateSeconds(r *pb.Bus_StopEstimate) int64 {
	if r.Estimate > 0 || r.StopStatus == 0 {
		return int64(r.Estimate)
	}
	return -1
}
