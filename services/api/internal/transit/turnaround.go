package transit

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/store"
	"go.uber.org/zap"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

// turnaroundSequence is the StopSequence the loader split this subroute's
// static payload at, or 0 when it serves TDX's own directions.
func (s *BusRouteserver) turnaroundSequence(ctx context.Context, subRouteUID string) int32 {
	if s.db == nil {
		return 0
	}
	seq, err := store.BusTurnaroundSequence(ctx, s.db, subRouteUID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		zap.S().Warnw("query failed", "component", "grpc", "action", "bus_turnaround", "event", "query_failed", "sub_route_uid", subRouteUID, "err", err)
	}
	return seq
}

// splitDailyAtTurnaround mirrors the static split onto the daily timetable,
// which stays one loop in Redis because the GTFS-RT feed reads it as such:
// each trip's stop times up to the turnaround become direction 0, those from
// it on direction 1.
func splitDailyAtTurnaround(tt *pb.Bus_DailyTimetables, seq int32) {
	loop := tt.GetDirection()[0]
	if loop == nil || tt.GetDirection()[1] != nil {
		return
	}
	out, back := &pb.Bus_DirectionTimetable{}, &pb.Bus_DirectionTimetable{}
	for _, trip := range loop.DailyTimetables {
		first, second := splitTrip(trip, seq)
		out.DailyTimetables = appendTrip(out.DailyTimetables, first)
		back.DailyTimetables = appendTrip(back.DailyTimetables, second)
	}
	tt.Direction[0], tt.Direction[1] = out, back
}

// appendTrip drops the half a trip never serves, such as the return half of a
// timetable that lists only its origin departure.
func appendTrip(trips []*pb.Bus_DailyTimetable, trip *pb.Bus_DailyTimetable) []*pb.Bus_DailyTimetable {
	if len(trip.StopTimes) == 0 {
		return trips
	}
	return append(trips, trip)
}

func splitTrip(trip *pb.Bus_DailyTimetable, seq int32) (*pb.Bus_DailyTimetable, *pb.Bus_DailyTimetable) {
	first := &pb.Bus_DailyTimetable{TripID: trip.TripID, IsLowFloor: trip.IsLowFloor}
	second := &pb.Bus_DailyTimetable{TripID: trip.TripID, IsLowFloor: trip.IsLowFloor}
	for _, st := range trip.StopTimes {
		if st.StopSequence <= seq {
			first.StopTimes = append(first.StopTimes, st)
		}
		if st.StopSequence >= seq {
			second.StopTimes = append(second.StopTimes, st)
		}
	}
	return first, second
}
