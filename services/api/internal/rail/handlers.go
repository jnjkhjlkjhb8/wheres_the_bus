package rail

import (
	"context"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// Delay implements the TRATimetableService Delay streaming RPC. The request
// carries no fields; it streams the system-wide TRA delay board via traDelay.
func (s *TraTimetableServer) Delay(_ *pb.AskRoute, stream pb.TRATimetableService_DelayServer) error {
	return s.traDelay(stream)
}

func (s *TraTimetableServer) Fare(ctx context.Context, in *pb.AskStaiton) (*pb.TraFareItems, error) {
	if in.StationId == "" || in.Date == "" {
		return nil, status.Error(codes.InvalidArgument, "origin and destination are required")
	}
	req := &pb.AskRoute{
		OriginStationId:      in.StationId,
		DestinationStationId: in.Date,
	}
	resp, err := s.traFare(ctx, req)
	if err != nil {
		return nil, err
	}
	items := &pb.TraFareItems{}
	if err := proto.Unmarshal(resp.Data, items); err != nil {
		return nil, status.Errorf(codes.Internal, "decode fare: %v", err)
	}
	if len(items.Items) == 0 {
		return nil, status.Error(codes.NotFound, "fare not found")
	}
	return items, nil
}

// Timetable returns the TRA timetable between two stations for the requested
// date. It decodes the cached payload from traTimetable and returns NotFound
// when the decoded set is empty.
func (s *TraTimetableServer) Timetable(ctx context.Context, in *pb.AskRoute) (*pb.TraTimetables, error) {
	resp, err := s.traTimetable(ctx, in)
	if err != nil {
		return nil, err
	}
	items := &pb.TraTimetables{}
	if err := proto.Unmarshal(resp.Data, items); err != nil {
		return nil, status.Errorf(codes.Internal, "decode timetable: %v", err)
	}
	if len(items.Items) == 0 {
		return nil, status.Error(codes.NotFound, "timetable not found")
	}
	return items, nil
}

func (s *TraTimetableServer) traDelay(stream pb.TRATimetableService_DelayServer) error {
	zap.S().Infow("call", "component", "grpc", "action", "tra_delay", "event", "call")
	return livestream.StreamLive(stream.Context(), s.live, livestream.LiveStreamSpec{
		Channel:  shared.TraDelayAllKey,
		SeedKeys: []string{shared.TraDelayAllKey},
	}, func(data []byte) error {
		delays, err := livestream.DecodePayload(data, &pb.TraDelays{})
		if err != nil {
			return err
		}
		return stream.Send(&pb.RespTraDelay{Data: delays})
	})
}

// Delay implements the TRA_DetainService Delay streaming RPC, streaming delay
// updates for the single train identified by in.Trainno via traDdelay.
func (s *TraDetainServer) Delay(in *pb.AskDetain, stream pb.TRA_DetainService_DelayServer) error {
	return s.traDdelay(in, stream)
}

// Stops returns the stop times for one TRA train, decoding the cached payload
// produced by traStops.
func (s *TraDetainServer) Stops(ctx context.Context, in *pb.AskDetain) (*pb.TraStoptimes, error) {
	resp, err := s.traStops(ctx, in)
	if err != nil {
		return nil, err
	}
	items := &pb.TraStoptimes{}
	if err := proto.Unmarshal(resp.Data, items); err != nil {
		return nil, status.Errorf(codes.Internal, "decode stops: %v", err)
	}
	return items, nil
}

func (s *TraDetainServer) traDdelay(in *pb.AskDetain, stream pb.TRA_DetainService_DelayServer) error {
	zap.S().Infow("call", "component", "grpc", "action", "tra_train_delay", "event", "call", "trainno", in.Trainno)
	// The realtime TRA job sets and publishes this key per train (traEta), so a
	// train absent from the current delay feed simply has no cached value and
	// the stream stays silent until one lands.
	key := shared.TraDelayTrainChannel(in.Trainno)
	return livestream.StreamLive(stream.Context(), s.live, livestream.LiveStreamSpec{
		Channel:  key,
		SeedKeys: []string{key},
	}, func(data []byte) error {
		delays, err := livestream.DecodePayload(data, &pb.TraDelays{})
		if err != nil {
			return err
		}
		return stream.Send(&pb.RespTraDelay{Data: delays})
	})
}

func (s *ThsrServer) Fare(ctx context.Context, in *pb.Ask_Thsr) (*pb.ThsaFares, error) {
	req := &pb.AskRoute{
		OriginStationId:      in.OriginStationId,
		DestinationStationId: in.DestinationStationId,
	}
	resp, err := s.thsrFare(ctx, req)
	if err != nil {
		return nil, err
	}
	items := &pb.ThsaFares{}
	if err := proto.Unmarshal(resp.Data, items); err != nil {
		return nil, status.Errorf(codes.Internal, "decode fare: %v", err)
	}
	if len(items.Items) == 0 {
		return nil, status.Error(codes.NotFound, "fare not found")
	}
	return items, nil
}

func (s *ThsrServer) AvailableSeats(in *pb.Ask_Thsr, stream grpc.ServerStreamingServer[pb.RespThsrSeats]) error {
	zap.S().Infow("log", "component", "grpc", "action", "thsr_available_seats", "date", in.Date)
	date := parseRailDate(in.Date).Format(time.DateOnly)
	return livestream.StreamLive(stream.Context(), s.live, livestream.LiveStreamSpec{
		Channel:  shared.ThsrSeatsPattern(date),
		SeedScan: shared.ThsrSeatsPattern(date),
	}, func(data []byte) error {
		seats, err := livestream.DecodePayload(data, &pb.ThsrAvailableSeats{})
		if err != nil {
			return err
		}
		return stream.Send(&pb.RespThsrSeats{Data: seats})
	})
}

// Timetable returns the THSR timetable between two stations for a date,
// decoding the cached payload produced by thsrTimetable.
func (s *ThsrServer) Timetable(ctx context.Context, in *pb.Ask_Thsr) (*pb.ThsrTimetables, error) {
	req := &pb.AskRoute{
		Date:                 in.Date,
		OriginStationId:      in.OriginStationId,
		DestinationStationId: in.DestinationStationId,
	}
	resp, err := s.thsrTimetable(ctx, req)
	if err != nil {
		return nil, err
	}
	items := &pb.ThsrTimetables{}
	if err := proto.Unmarshal(resp.Data, items); err != nil {
		return nil, status.Errorf(codes.Internal, "decode timetable: %v", err)
	}
	return items, nil
}

// Stops returns the stop times for one THSR train, decoding the cached payload
// produced by thsrStops.
func (s *ThsrDetainServer) Stops(ctx context.Context, in *pb.ThsrAskDetain) (*pb.ThsrStoptimes, error) {
	resp, err := s.thsrStops(ctx, in)
	if err != nil {
		return nil, err
	}
	items := &pb.ThsrStoptimes{}
	if err := proto.Unmarshal(resp.Data, items); err != nil {
		return nil, status.Errorf(codes.Internal, "decode stops: %v", err)
	}
	return items, nil
}
