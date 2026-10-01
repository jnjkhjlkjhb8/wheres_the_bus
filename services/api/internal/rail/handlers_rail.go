package rail

import (
	"context"
	"fmt"
	"strings"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/store"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// parseRailDate parses the app's 'yyyy-MM-dd' date strings, accepting RFC3339
// too for any legacy caller. Returns the zero time only when neither parses.
func parseRailDate(s string) time.Time {
	if t, err := time.Parse(time.DateOnly, s); err == nil {
		return t
	}
	t, _ := time.Parse(time.RFC3339, s)
	return t
}

const (
	// A station board is a glance, not a timetable: enough rows to cover the
	// next stretch at a busy station without making the rider wait for a day.
	_stationBoardDefaultLimit = 20
	_stationBoardMaxLimit     = 50
)

func stationBoardLimit(requested int32) int {
	switch {
	case requested <= 0:
		return _stationBoardDefaultLimit
	case requested > _stationBoardMaxLimit:
		return _stationBoardMaxLimit
	default:
		return int(requested)
	}
}

func departuresAfter[T interface{ GetDepartureTime() string }](items []T, after string) []T {
	out := make([]T, 0, len(items))
	for _, item := range items {
		if after == "" || item.GetDepartureTime() >= after {
			out = append(out, item)
		}
	}
	return out
}

func stationBoardWindow[T interface{ GetDepartureTime() string }](
	day []T,
	after string,
	limit int,
	nextDay func() ([]T, error),
) ([]T, error) {
	items := departuresAfter(day, after)
	var topUpErr error
	if len(items) < limit {
		next, err := nextDay()
		if err != nil {
			topUpErr = err
		} else {
			items = append(items, next...)
		}
	}
	if len(items) > limit {
		items = items[:limit]
	}
	return items, topUpErr
}

const (
	// Boards, timetables and stop times all describe one service day, which only
	// changes when the nightly load lands, so an hour is a compromise between
	// staleness and DB load rather than a per-dataset judgement.
	_railDayTTL = 1 * time.Hour
	// Fares change only on a load and are the same for every rider all day, so
	// they are held far longer. Bump the key's :v prefix, not this TTL, when the
	// payload shape changes: the old entries would otherwise outlive the deploy.
	_railFareTTL = 8 * time.Hour
)

func railCacheStation(s string) string {
	return strings.ReplaceAll(strings.TrimSpace(s), "臺", "台")
}

// railCacheDate normalises a service date for cache-key use. The wire accepts
// both 'yyyy-MM-dd' and RFC3339 (see parseRailDate), so keying on the raw string
// minted one entry per spelling of the same day.
func railCacheDate(s string) string {
	return parseRailDate(s).Format(time.DateOnly)
}

func railRead(
	ctx context.Context,
	rc *redis.Client,
	action, key string,
	ttl time.Duration,
	load func(context.Context) ([]byte, int, error),
) ([]byte, error) {
	if b, err := rc.Get(ctx, key).Bytes(); err == nil && len(b) > 0 {
		return b, nil
	}
	b, n, err := load(ctx)
	if err != nil {
		return nil, err
	}
	if n == 0 || len(b) == 0 {
		return nil, nil
	}
	if err := rc.Set(ctx, key, b, ttl).Err(); err != nil {
		zap.S().Errorw("cache error", "component", "grpc", "action", action, "event", "cache_error", "err", err)
	}
	return b, nil
}

func (s *TraTimetableServer) traStationBoardDay(ctx context.Context, station string, day time.Time, direction int32) ([]*pb.TraStationDeparture, error) {
	key := fmt.Sprintf("TRA_StationBoard:%s:%s:%d", day.Format(time.DateOnly), railCacheStation(station), direction)
	b, err := railRead(ctx, s.rc, "tra_station_board", key, _railDayTTL, func(ctx context.Context) ([]byte, int, error) {
		items, err := TRAStationBoardPayload(ctx, s.db, station, day, direction)
		if err != nil || len(items) == 0 {
			return nil, 0, err
		}
		payload, err := proto.Marshal(&pb.TraStationBoard{Items: items})
		return payload, len(items), err
	})
	if err != nil || b == nil {
		return nil, err
	}
	board := &pb.TraStationBoard{}
	if err := proto.Unmarshal(b, board); err != nil {
		return nil, err
	}
	return board.Items, nil
}

func (s *TraTimetableServer) StationBoard(ctx context.Context, in *pb.AskStationBoard) (*pb.TraStationBoard, error) {
	zap.S().Infow("call",
		"component", "grpc",
		"action", "tra_station_board",
		"event", "call",
		"station", in.StationId,
		"direction", in.Direction,
	)
	if in.StationId == "" {
		return nil, status.Error(codes.InvalidArgument, "station is required")
	}
	day := parseRailDate(in.Date)
	if day.IsZero() {
		return nil, status.Error(codes.InvalidArgument, "date is required")
	}
	limit := stationBoardLimit(in.Limit)
	today, err := s.traStationBoardDay(ctx, in.StationId, day, in.Direction)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "tra_station_board",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "station board not found")
	}
	items, topUpErr := stationBoardWindow(today, in.After, limit, func() ([]*pb.TraStationDeparture, error) {
		return s.traStationBoardDay(ctx, in.StationId, day.AddDate(0, 0, 1), in.Direction)
	})
	if topUpErr != nil {
		zap.S().Errorw("topup failed",
			"component", "grpc",
			"action", "tra_station_board",
			"event", "topup_failed",
			"err", topUpErr,
		)
	}
	// NotFound means the day is not landed, not "no trains left": a landed day
	// whose remaining departures have all gone is a real answer of zero, and
	// the app tells the rider the day is over rather than that it is broken.
	if len(today) == 0 && len(items) == 0 {
		return nil, status.Error(codes.NotFound, "station board not found")
	}
	return &pb.TraStationBoard{Items: items}, nil
}

// thsrStationBoardDay is traStationBoardDay's THSR half; see it for why the
// whole day is cached and why an empty day is not.
func (s *ThsrServer) thsrStationBoardDay(ctx context.Context, station string, day time.Time, direction int32) ([]*pb.ThsrStationDeparture, error) {
	key := fmt.Sprintf("THSR_StationBoard:%s:%s:%d", day.Format(time.DateOnly), railCacheStation(station), direction)
	b, err := railRead(ctx, s.rc, "thsr_station_board", key, _railDayTTL, func(ctx context.Context) ([]byte, int, error) {
		items, err := THSRStationBoardPayload(ctx, s.db, station, day, direction)
		if err != nil || len(items) == 0 {
			return nil, 0, err
		}
		payload, err := proto.Marshal(&pb.ThsrStationBoard{Items: items})
		return payload, len(items), err
	})
	if err != nil || b == nil {
		return nil, err
	}
	board := &pb.ThsrStationBoard{}
	if err := proto.Unmarshal(b, board); err != nil {
		return nil, err
	}
	return board.Items, nil
}

// StationBoard returns the next departures from one THSR station in one
// direction, with the same next-day top-up as the TRA board.
func (s *ThsrServer) StationBoard(ctx context.Context, in *pb.ThsrAskStationBoard) (*pb.ThsrStationBoard, error) {
	zap.S().Infow("call",
		"component", "grpc",
		"action", "thsr_station_board",
		"event", "call",
		"station", in.StationId,
		"direction", in.Direction,
	)
	if in.StationId == "" {
		return nil, status.Error(codes.InvalidArgument, "station is required")
	}
	day := parseRailDate(in.Date)
	if day.IsZero() {
		return nil, status.Error(codes.InvalidArgument, "date is required")
	}
	limit := stationBoardLimit(in.Limit)
	today, err := s.thsrStationBoardDay(ctx, in.StationId, day, in.Direction)
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "thsr_station_board",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "station board not found")
	}
	items, topUpErr := stationBoardWindow(today, in.After, limit, func() ([]*pb.ThsrStationDeparture, error) {
		return s.thsrStationBoardDay(ctx, in.StationId, day.AddDate(0, 0, 1), in.Direction)
	})
	if topUpErr != nil {
		zap.S().Errorw("topup failed",
			"component", "grpc",
			"action", "thsr_station_board",
			"event", "topup_failed",
			"err", topUpErr,
		)
	}
	// See the TRA board: NotFound is "not landed", an empty board is "the day
	// is over".
	if len(today) == 0 && len(items) == 0 {
		return nil, status.Error(codes.NotFound, "station board not found")
	}
	return &pb.ThsrStationBoard{Items: items}, nil
}

func (s *TraTimetableServer) traFare(ctx context.Context, in *pb.AskRoute) (*pb.Resp_Data, error) {
	zap.S().Infow("call",
		"component", "grpc",
		"action", "tra_fare",
		"event", "call",
		"origin", in.OriginStationId,
		"dest", in.DestinationStationId,
	)
	// Key version (:v2) bumped when the payload widened from adult-only to every
	// 票種; without it the deploy would serve adult-only sets for a further 8h.
	key := fmt.Sprintf("TRA_Fare:v2:%s:%s", railCacheStation(in.OriginStationId), railCacheStation(in.DestinationStationId))
	b, err := railRead(ctx, s.rc, "tra_fare", key, _railFareTTL, func(ctx context.Context) ([]byte, int, error) {
		payload, err := TRAFarePayload(ctx, s.db, in.OriginStationId, in.DestinationStationId)
		return payload, len(payload), err
	})
	if err != nil {
		zap.S().Errorw("query failed", "component", "grpc", "action", "tra_fare", "event", "query_failed", "err", err)
		return nil, store.GRPCStatusFor(err, "fare not found")
	}
	if b == nil {
		return nil, status.Error(codes.NotFound, "fare not found")
	}
	return &pb.Resp_Data{Data: b}, nil
}

func (s *ThsrServer) thsrFare(ctx context.Context, in *pb.AskRoute) (*pb.Resp_Data, error) {
	zap.S().Infow("call",
		"component", "grpc",
		"action", "thsr_fare",
		"event", "call",
		"origin", in.OriginStationId,
		"dest", in.DestinationStationId,
	)
	// Key version (:v2) bumped for the same reason as TRA_Fare: the payload now
	// carries every fare class and cabin class, not just the standard adult seat.
	key := fmt.Sprintf("THSR_Fare:v2:%s:%s", railCacheStation(in.OriginStationId), railCacheStation(in.DestinationStationId))
	b, err := railRead(ctx, s.rc, "thsr_fare", key, _railFareTTL, func(ctx context.Context) ([]byte, int, error) {
		items, err := QueryTHSRFares(ctx, s.db, in.OriginStationId, in.DestinationStationId)
		if err != nil || len(items) == 0 {
			return nil, 0, err
		}
		payload, err := proto.Marshal(&pb.ThsaFares{Items: items})
		return payload, len(items), err
	})
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "thsr_fare",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "fare not found")
	}
	if b == nil {
		return nil, status.Error(codes.NotFound, "fare not found")
	}
	return &pb.Resp_Data{Data: b}, nil
}

func (s *TraTimetableServer) traTimetable(ctx context.Context, in *pb.AskRoute) (*pb.Resp_Data, error) {
	zap.S().Infow("call",
		"component", "grpc",
		"action", "tra_timetable",
		"event", "call",
		"origin", in.OriginStationId,
		"dest", in.DestinationStationId,
	)
	da := parseRailDate(in.Date)
	key := fmt.Sprintf("TRA_timetable:%s:%s:%s", railCacheDate(in.Date), railCacheStation(in.OriginStationId), railCacheStation(in.DestinationStationId))
	b, err := railRead(ctx, s.rc, "tra_timetable", key, _railDayTTL, func(ctx context.Context) ([]byte, int, error) {
		return TRATimetablePayload(ctx, s.db, in.OriginStationId, in.DestinationStationId, da)
	})
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "tra_timetable",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "timetable not found")
	}
	if b == nil {
		return nil, status.Error(codes.NotFound, "timetable not found")
	}
	return &pb.Resp_Data{Data: b}, nil
}

func (s *ThsrServer) thsrTimetable(ctx context.Context, in *pb.AskRoute) (*pb.Resp_Data, error) {
	zap.S().Infow("call",
		"component", "grpc",
		"action", "thsr_timetable",
		"event", "call",
		"origin", in.OriginStationId,
		"dest", in.DestinationStationId,
	)
	da := parseRailDate(in.Date)
	key := fmt.Sprintf("THSR_timetable:%s:%s:%s", railCacheDate(in.Date), railCacheStation(in.OriginStationId), railCacheStation(in.DestinationStationId))
	b, err := railRead(ctx, s.rc, "thsr_timetable", key, _railDayTTL, func(ctx context.Context) ([]byte, int, error) {
		return THSRTimetablePayload(ctx, s.db, in.OriginStationId, in.DestinationStationId, da)
	})
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "thsr_timetable",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "timetable not found")
	}
	if b == nil {
		return nil, status.Error(codes.NotFound, "timetable not found")
	}
	return &pb.Resp_Data{Data: b}, nil
}

func (s *TraDetainServer) traStops(ctx context.Context, in *pb.AskDetain) (*pb.Resp_Data, error) {
	zap.S().Infow("call", "component", "grpc", "action", "tra_stops", "event", "call", "train", in.Trainno)
	date := railCacheDate(in.Date)
	key := fmt.Sprintf("TRA_Stoptimes:%s:%s", date, in.Trainno)
	b, err := railRead(ctx, s.rc, "tra_stops", key, _railDayTTL, func(ctx context.Context) ([]byte, int, error) {
		return TRAStoptimesPayload(ctx, s.db, in.Trainno, date)
	})
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "tra_stops",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "stops not found")
	}
	if b == nil {
		return nil, status.Error(codes.NotFound, "stops not found")
	}
	return &pb.Resp_Data{Data: b}, nil
}

func (s *ThsrDetainServer) thsrStops(ctx context.Context, in *pb.ThsrAskDetain) (*pb.Resp_Data, error) {
	zap.S().Infow("call", "component", "grpc", "action", "thsr_stops", "event", "call", "train", in.Trainno)
	date := railCacheDate(in.Date)
	key := fmt.Sprintf("THSR_Stoptimes:%s:%s", date, in.Trainno)
	b, err := railRead(ctx, s.rc, "thsr_stops", key, _railDayTTL, func(ctx context.Context) ([]byte, int, error) {
		return THSRStoptimesPayload(ctx, s.db, in.Trainno, date)
	})
	if err != nil {
		zap.S().Errorw("query failed",
			"component", "grpc",
			"action", "thsr_stops",
			"event", "query_failed",
			"err", err,
		)
		return nil, store.GRPCStatusFor(err, "stops not found")
	}
	if b == nil {
		return nil, status.Error(codes.NotFound, "stops not found")
	}
	return &pb.Resp_Data{Data: b}, nil
}
