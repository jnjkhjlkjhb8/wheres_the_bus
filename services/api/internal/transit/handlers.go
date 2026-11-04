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
	if data, ok := s.cachedBusStatic(route); ok {
		return busStaticResponse(data)
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
	s.cacheBusStatic(route, data)
	return busStaticResponse(data)
}

func (s *BusRouteserver) cachedBusStatic(route string) ([]byte, bool) {
	if s.cache == nil {
		return nil, false
	}
	return s.cache.Get("bus_static:" + route)
}

func (s *BusRouteserver) cacheBusStatic(route string, data []byte) {
	if s.cache != nil {
		s.cache.Set("bus_static:"+route, data, time.Hour)
	}
}

func busStaticResponse(data []byte) (*pb.Resp_BusStatic, error) {
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
	city, err := stationEtaCity(stream.Context(), db, in)
	if err != nil {
		return err
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

func stationEtaCity(ctx context.Context, db store.DB, in *pb.Bus_Ask_StationGroup) (string, error) {
	if in.GroupUid == "" {
		return "", status.Error(codes.InvalidArgument, "station eta key must include group_uid")
	}
	city := resolveStationEtaCity(ctx, db, in)
	if city == "" {
		return "", status.Error(codes.InvalidArgument, "station eta key must include city or known group_uid")
	}
	return city, nil
}

func resolveStationEtaCity(ctx context.Context, db store.DB, in *pb.Bus_Ask_StationGroup) string {
	if in.City != "" || db == nil {
		return in.City
	}
	city, err := store.BusStationGroupCity(ctx, db, in.GroupUid)
	if err != nil {
		return ""
	}
	return city
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
	if seq := s.turnaroundSequence(ctx, route); seq > 0 {
		splitDailyAtTurnaround(tt, seq)
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
	return busStationGroup(ctx, s.db, groupUID)
}

func busStationGroup(ctx context.Context, db store.DB, groupUID string) (*pb.Bus_StationGroup, error) {
	header, err := store.BusStationGroupHeader(ctx, db, groupUID)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "bus_station_group",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "station group not found")
	}
	members, err := store.BusStationGroupMembers(ctx, db, groupUID)
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
	if resp, ok := s.cachedBikeStatic(in.StationUID); ok {
		return resp, nil
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
	resp := bikeStaticResponse(in.StationUID, row)
	s.cacheBikeStatic(in.StationUID, resp)
	return resp, nil
}

func (s *BikeServer) cacheBikeStatic(uid string, resp *pb.BikeStatic) {
	if s.cache != nil {
		if data, err := proto.Marshal(resp); err == nil {
			s.cache.Set("bike_static:"+uid, data, time.Hour)
		}
	}
}

func (s *BikeServer) cachedBikeStatic(uid string) (*pb.BikeStatic, bool) {
	if s.cache == nil {
		return nil, false
	}
	data, ok := s.cache.Get("bike_static:" + uid)
	if !ok {
		return nil, false
	}
	var resp pb.BikeStatic
	if err := proto.Unmarshal(data, &resp); err != nil {
		return nil, false
	}
	return &resp, true
}

func bikeStaticResponse(uid string, row store.BikeStaticRow) *pb.BikeStatic {
	resp := &pb.BikeStatic{
		StationUID:  uid,
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
	return resp
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
		recvErr = queueNearRequests(stream, requests)
	}()
	return requests, &recvErr
}

func queueNearRequests(stream pb.Near_Station_Service_NearServer, requests chan *pb.Ask_Near) error {
	for {
		in, err := stream.Recv()
		if err != nil {
			return nearReceiveError(err)
		}
		queueLatestNearRequest(requests, in)
	}
}

func nearReceiveError(err error) error {
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func queueLatestNearRequest(requests chan *pb.Ask_Near, in *pb.Ask_Near) {
	// Sole producer, so the slot cannot refill between the drain and the send.
	select {
	case <-requests:
	default:
	}
	requests <- in
}

func (s *NearServer) FindNear(stream pb.Near_Station_Service_NearServer) error {
	ctx := stream.Context()
	requests, recvErr := latestNearRequest(stream)
	var lastQueryAt time.Time
	for {
		in, err := receiveNearRequest(ctx, requests, recvErr)
		if nearRequestEnded(in, err) {
			return err
		}
		// Enforce a per-stream work cadence regardless of how far the client
		// jumps. The receiver keeps only the latest queued value, so waiting
		// here still delivers the newest position without allowing a flood.
		if err := s.sendNearRequest(stream, in, &lastQueryAt); err != nil {
			return err
		}
	}
}

func nearRequestEnded(in *pb.Ask_Near, err error) bool {
	return err != nil || in == nil
}

func (s *NearServer) sendNearRequest(stream pb.Near_Station_Service_NearServer, in *pb.Ask_Near, lastQueryAt *time.Time) error {
	if err := waitNearCadence(stream.Context(), *lastQueryAt); err != nil {
		return err
	}
	*lastQueryAt = time.Now()
	resp, err := s.discoverNearRequest(stream.Context(), in)
	if err != nil {
		return nearbyRPCError(err)
	}
	return sendDiscoveredNear(stream, resp)
}

func sendDiscoveredNear(stream pb.Near_Station_Service_NearServer, resp *pb.RespNear) error {
	if err := stream.Send(resp); err != nil {
		zap.S().Errorw("failed", "component", "grpc", "action", "send_newdata", "err", err)
		return err
	}
	zap.S().Infow("success", "component", "grpc", "action", "send_newdata", "event", "success")
	return nil
}

func (s *NearServer) discoverNearRequest(ctx context.Context, in *pb.Ask_Near) (*pb.RespNear, error) {
	zap.S().Infow("received nearby query", "component", "grpc", "radius", in.Radius)
	started := time.Now()
	resp, err := s.discovery.Discover(ctx, nearby.NearbyQuery{
		Origin: nearby.GeoPoint{Lon: in.PositionLon, Lat: in.PositionLat}, RadiusMeters: int(in.Radius),
	})
	// Server-side cost lets a slow first paint be attributed to the router.
	zap.S().Infow("done", "component", "near", "action", "discover", "event", "done",
		"elapsed_ms", time.Since(started).Milliseconds())
	return resp, err
}

func receiveNearRequest(ctx context.Context, requests <-chan *pb.Ask_Near, recvErr *error) (*pb.Ask_Near, error) {
	select {
	case <-ctx.Done():
		// Channel closure joins the receiver before reading its final error.
		drainNearRequests(requests)
		return nil, ctx.Err()
	case in, ok := <-requests:
		return receivedNearRequest(in, ok, recvErr)
	}
}

func receivedNearRequest(in *pb.Ask_Near, ok bool, recvErr *error) (*pb.Ask_Near, error) {
	if !ok {
		return nil, *recvErr
	}
	return in, nil
}

func drainNearRequests(requests <-chan *pb.Ask_Near) {
	for range requests {
	}
}

func waitNearCadence(ctx context.Context, lastQueryAt time.Time) error {
	if lastQueryAt.IsZero() {
		return nil
	}
	wait := 100*time.Millisecond - time.Since(lastQueryAt)
	if wait <= 0 {
		return nil
	}
	return waitNearTimer(ctx, wait)
}

func waitNearTimer(ctx context.Context, wait time.Duration) error {
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func nearbyRPCError(err error) error {
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

func busEtaDemandKey(city string) string {
	if city == "" {
		return ""
	}
	return shared.LiveDemandKey("bus_eta", city)
}

func usableBusEtaPayload(data []byte) bool {
	return len(data) > 0
}
