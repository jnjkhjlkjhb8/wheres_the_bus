package transit

import (
	"context"
	"errors"
	"io"
	"strconv"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/nearby"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/store"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// Static implements the Bus_Route_Service Static RPC by delegating to
// BusRouteStatic.
func (s *BusRouteserver) Static(ctx context.Context, in *pb.Bus_Ask_Route) (*pb.Resp_BusStatic, error) {
	return s.BusRouteStatic(ctx, in)
}

// Daily implements the Daily RPC, returning the cached daily timetable payload
// produced by BusDailytable wrapped in the RPC's response type.
func (s *BusRouteserver) Daily(ctx context.Context, in *pb.Bus_Ask_Route) (*pb.Resp_BusDailyTimetable, error) {
	return s.BusDailytable(ctx, in)
}

// Eta implements the Bus_Route_Service Eta streaming RPC by delegating to
// BusRouteEta.
func (s *BusRouteserver) Eta(in *pb.Bus_Ask_Route, stream pb.Bus_Route_Service_EtaServer) error {
	return s.BusRouteEta(in, stream)
}

func (s *BusRouteserver) BusRouteStatic(ctx context.Context, in *pb.Bus_Ask_Route) (*pb.Resp_BusStatic, error) {
	zap.S().Infow("call", "component", "grpc", "action", "bus_static", "event", "call", "sub_route_uid", in.SubRouteUID)
	route := in.SubRouteUID
	if s.cache != nil {
		if data, ok := s.cache.Get("bus_static:" + route); ok {
			sub, err := livestream.DecodePayload(data, &pb.BusSubroute{})
			if err != nil {
				return nil, err
			}
			return &pb.Resp_BusStatic{Data: sub}, nil
		}
	}
	data, err := store.BusStaticPayload(ctx, s.db, route)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "bus_static",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "route not found")
	}
	if s.cache != nil {
		s.cache.Set("bus_static:"+route, data, time.Hour)
	}
	sub, err := livestream.DecodePayload(data, &pb.BusSubroute{})
	if err != nil {
		return nil, err
	}
	return &pb.Resp_BusStatic{Data: sub}, nil
}

func (s *BusRouteserver) BusRouteEta(in *pb.Bus_Ask_Route, stream pb.Bus_Route_Service_EtaServer) error {
	zap.S().Infow("call", "component", "grpc", "action", "bus_route_eta", "event", "call", "sub_route_uid", in.SubRouteUID)
	key := shared.BusRouteEtaKey(in.SubRouteUID)
	return livestream.StreamLive(stream.Context(), s.live, livestream.LiveStreamSpec{
		Channel:   key,
		SeedKeys:  []string{key},
		Usable:    usableBusEtaPayload,
		DemandKey: busEtaDemandKey(shared.CityFromUID(in.SubRouteUID)),
	}, func(data []byte) error {
		arrival, err := livestream.DecodePayload(data, &pb.Bus_RouteArrival{})
		if err != nil {
			return err
		}
		return stream.Send(&pb.Resp_BusEta{Data: arrival})
	})
}

func streamBusStationEta(db store.DB, live livestream.LiveSource, in *pb.Bus_Ask_StationGroup, stream pb.Bus_Station_Service_EtaServer) error {
	zap.S().Infow("call", "component", "grpc", "action", "bus_station_eta", "event", "call", "city", in.City, "group_uid", in.GroupUid)
	groupUID := in.GroupUid
	if groupUID == "" {
		return status.Error(codes.InvalidArgument, "station eta key must include group_uid")
	}
	city := in.City
	if city == "" && db != nil {
		if dbCity, err := store.BusStationGroupCity(stream.Context(), db, groupUID); err == nil {
			city = dbCity
		}
	}
	if city == "" {
		return status.Error(codes.InvalidArgument, "station eta key must include city or known group_uid")
	}
	key := shared.BusStationEtaKey(city, groupUID)
	return livestream.StreamLive(stream.Context(), live, livestream.LiveStreamSpec{
		Channel:   key,
		SeedKeys:  []string{key},
		Usable:    usableBusEtaPayload,
		DemandKey: busEtaDemandKey(city),
	}, func(data []byte) error {
		arrival, err := livestream.DecodePayload(data, &pb.Bus_StationArrival{})
		if err != nil {
			return err
		}
		return stream.Send(&pb.Resp_BusStationEta{Data: arrival})
	})
}

func (s *BusRouteserver) BusDailytable(ctx context.Context, in *pb.Bus_Ask_Route) (*pb.Resp_BusDailyTimetable, error) {
	zap.S().Infow("call", "component", "grpc", "action", "bus_dailytable", "event", "call", "sub_route_uid", in.SubRouteUID)
	route := in.SubRouteUID
	val, err := s.rc.Get(ctx, shared.BusDailyTimetableKey(route)).Result()
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "bus_dailytable",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "timetable not found")
	}
	tt, err := livestream.DecodePayload([]byte(val), &pb.Bus_DailyTimetables{})
	if err != nil {
		return nil, err
	}
	return &pb.Resp_BusDailyTimetable{Data: tt}, nil
}

// Eta implements the Bus_Station_Service Eta streaming RPC by delegating to the
// shared streamBusStationEta helper.
func (s *BusStationserver) Eta(in *pb.Bus_Ask_StationGroup, stream pb.Bus_Station_Service_EtaServer) error {
	return streamBusStationEta(s.db, s.live, in, stream)
}

// Group returns a station group and its member stops from PostgreSQL. It
// returns InvalidArgument for an empty group_uid, NotFound when the group does
// not exist, and Internal for a transient query failure.
func (s *BusStationserver) Group(ctx context.Context, in *pb.Bus_Ask_StationGroup) (*pb.Bus_StationGroup, error) {
	groupUID := in.GroupUid
	if groupUID == "" {
		return nil, status.Error(codes.InvalidArgument, "group_uid required")
	}
	header, err := store.BusStationGroupHeader(ctx, s.db, groupUID)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "bus_station_group",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "station group not found")
	}
	members, err := store.BusStationGroupMembers(ctx, s.db, groupUID)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "station group members: %v", err)
	}
	return &pb.Bus_StationGroup{
		GroupUid:    groupUID,
		GroupName:   header.GroupName,
		City:        header.City,
		PositionLon: header.Lon,
		PositionLat: header.Lat,
		Members:     members,
	}, nil
}

// Static implements the Bike_Service Static RPC by delegating to BikeStatic.
func (s *BikeServer) Static(ctx context.Context, in *pb.BikeRequest) (*pb.BikeStatic, error) {
	return s.BikeStatic(ctx, in)
}

// Eta implements the Bike_Service Eta streaming RPC by delegating to bikeEta.
func (s *BikeServer) Eta(in *pb.BikeRequest, stream pb.Bike_Service_EtaServer) error {
	return s.bikeEta(in, stream)
}

func (s *BikeServer) BikeStatic(ctx context.Context, in *pb.BikeRequest) (*pb.BikeStatic, error) {
	zap.S().Infow("call", "component", "grpc", "action", "bike_static", "event", "call", "station_uid", in.StationUID)
	if s.cache != nil {
		if data, ok := s.cache.Get("bike_static:" + in.StationUID); ok {
			var resp pb.BikeStatic
			if proto.Unmarshal(data, &resp) == nil {
				return &resp, nil
			}
		}
	}
	row, err := store.BikeStaticData(ctx, s.db, in.StationUID)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "bike_static",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "bike station not found")
	}
	resp := &pb.BikeStatic{
		StationUID:  in.StationUID,
		Name:        row.Name,
		Capacity:    row.Capacity,
		ServiceType: row.ServiceType,
		Address:     row.Address,
	}
	// Left empty when the station landed without a point, so a client reads a
	// missing coordinate as missing rather than as the origin off West Africa.
	if row.Lat != nil && row.Lon != nil {
		resp.Lat = strconv.FormatFloat(*row.Lat, 'f', 6, 64)
		resp.Lon = strconv.FormatFloat(*row.Lon, 'f', 6, 64)
	}
	if s.cache != nil {
		if data, err := proto.Marshal(resp); err == nil {
			s.cache.Set("bike_static:"+in.StationUID, data, time.Hour)
		}
	}
	return resp, nil
}

func (s *BikeServer) bikeEta(in *pb.BikeRequest, stream pb.Bike_Service_EtaServer) error {
	zap.S().Infow("call", "component", "grpc", "action", "bike_eta", "event", "call", "station_uid", in.StationUID)
	key := shared.BikeAvailabilityKey(in.StationUID)
	demand := ""
	if city := shared.CityFromUID(in.StationUID); city != "" {
		demand = shared.LiveDemandKey("bike", city)
	}
	return livestream.StreamLive(stream.Context(), s.live, livestream.LiveStreamSpec{
		Channel:   key,
		SeedKeys:  []string{key},
		DemandKey: demand,
	}, func(data []byte) error {
		eta, err := livestream.DecodePayload(data, &pb.BikeEta{})
		if err != nil {
			return err
		}
		return stream.Send(&pb.Resp_BikeEta{Data: eta})
	})
}

// Near implements the Near_Station_Service Near bidirectional RPC by delegating
// to FindNear.
func (s *NearServer) Near(stream pb.Near_Station_Service_NearServer) error {
	return s.FindNear(stream)
}

func latestNearRequest(stream pb.Near_Station_Service_NearServer) (<-chan *pb.Ask_Near, *error) {
	requests := make(chan *pb.Ask_Near, 1)
	var recvErr error
	go func() {
		defer close(requests)
		for {
			in, err := stream.Recv()
			if err != nil {
				if !errors.Is(err, io.EOF) {
					recvErr = err
				}
				return
			}
			// Sole producer, so the slot cannot refill between the drain and
			// the send and the send cannot block.
			select {
			case <-requests:
			default:
			}
			requests <- in
		}
	}()
	return requests, &recvErr
}

func (s *NearServer) FindNear(stream pb.Near_Station_Service_NearServer) error {
	ctx := stream.Context()
	requests, recvErr := latestNearRequest(stream)
	var lastQueryAt time.Time
	for {
		var in *pb.Ask_Near
		select {
		case <-ctx.Done():
			// The drain goroutine's only exit signal is requests closing; wait
			// for it here rather than returning while it is still running, per
			// "Wait for goroutines to exit" (docs/go-style/goroutine-exit.md).
			for range requests {
			}
			return ctx.Err()
		case next, ok := <-requests:
			if !ok {
				return *recvErr
			}
			in = next
		}
		lon := in.PositionLon
		lat := in.PositionLat
		r := in.Radius
		// Enforce a per-stream work cadence regardless of how far the client
		// jumps. The receiver keeps only the latest queued value, so waiting
		// here still delivers the newest position without allowing a flood.
		if !lastQueryAt.IsZero() {
			wait := 100*time.Millisecond - time.Since(lastQueryAt)
			if wait > 0 {
				timer := time.NewTimer(wait)
				select {
				case <-timer.C:
				case <-ctx.Done():
					timer.Stop()
					return ctx.Err()
				}
			}
		}
		lastQueryAt = time.Now()
		zap.S().Infow("received nearby query", "component", "grpc", "radius", r)
		started := time.Now()
		resp, err := s.discovery.Discover(ctx, nearby.NearbyQuery{
			Origin: nearby.GeoPoint{Lon: lon, Lat: lat}, RadiusMeters: int(r),
		})
		// Server-side cost of one nearby query, so a slow first paint can be
		// attributed to the router or ruled out without a second round of logs.
		zap.S().Infow("done",
			"component", "near",
			"action", "discover",
			"event", "done",
			"elapsed_ms", time.Since(started).Milliseconds(),
		)
		if err != nil {
			if errors.Is(err, nearby.ErrInvalidNearbyQuery) {
				zap.S().Warnw("invalid",
					"component", "grpc",
					"action", "nearby_discovery",
					"event", "invalid",
					"err", err,
				)
				return status.Error(codes.InvalidArgument, err.Error())
			}
			zap.S().Errorw("failed", "component", "grpc", "action", "nearby_discovery", "err", err)
			if errors.Is(err, nearby.ErrNearbyUnavailable) {
				return status.Error(codes.Unavailable, "nearby discovery unavailable")
			}
			return err
		}
		if err := stream.Send(resp); err != nil {
			zap.S().Errorw("failed", "component", "grpc", "action", "send_newdata", "err", err)
			return err
		}
		zap.S().Infow("success", "component", "grpc", "action", "send_newdata", "event", "success")
	}
}

func busEtaDemandKey(city string) string {
	if city == "" {
		return ""
	}
	return shared.LiveDemandKey("bus_eta", city)
}

func usableBusEtaPayload(data []byte) bool {
	return len(data) > 0
}
