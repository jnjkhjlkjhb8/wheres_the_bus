package transit

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/protobuf/proto"
)

func loopTrip(id string, seqs ...int32) *pb.Bus_DailyTimetable {
	trip := &pb.Bus_DailyTimetable{TripID: id, IsLowFloor: true}
	for _, s := range seqs {
		trip.StopTimes = append(trip.StopTimes, &pb.Bus_StopTime{StopSequence: s, DepartureTime: fmt.Sprintf("06:%02d", s)})
	}
	return trip
}

func sequences(trip *pb.Bus_DailyTimetable) []int32 {
	out := make([]int32, 0, len(trip.StopTimes))
	for _, st := range trip.StopTimes {
		out = append(out, st.StopSequence)
	}
	return out
}

func TestSplitDailyAtTurnaround(t *testing.T) {
	tt := &pb.Bus_DailyTimetables{Direction: map[int32]*pb.Bus_DirectionTimetable{0: {DailyTimetables: []*pb.Bus_DailyTimetable{
		loopTrip("full", 1, 2, 3, 4, 5, 6, 7),
		loopTrip("origin-only", 1),
		loopTrip("tail-only", 5, 6),
	}}}}
	splitDailyAtTurnaround(tt, 4)

	out, back := tt.Direction[0].DailyTimetables, tt.Direction[1].DailyTimetables
	if len(out) != 2 || fmt.Sprint(sequences(out[0])) != "[1 2 3 4]" || out[1].TripID != "origin-only" {
		t.Fatalf("去程 trips = %v", out)
	}
	if len(back) != 2 || fmt.Sprint(sequences(back[0])) != "[4 5 6 7]" || back[1].TripID != "tail-only" {
		t.Fatalf("返程 trips = %v", back)
	}
	if !back[0].IsLowFloor || back[0].TripID != "full" {
		t.Fatalf("返程 trip must keep its identity, got %v", back[0])
	}
}

func TestSplitDailyAtTurnaroundLeavesRealDirectionsAlone(t *testing.T) {
	two := &pb.Bus_DailyTimetables{Direction: map[int32]*pb.Bus_DirectionTimetable{
		0: {DailyTimetables: []*pb.Bus_DailyTimetable{loopTrip("a", 1, 2, 3)}},
		1: {DailyTimetables: []*pb.Bus_DailyTimetable{loopTrip("b", 1, 2)}},
	}}
	want := proto.Clone(two)
	splitDailyAtTurnaround(two, 2)
	if !proto.Equal(two, want) {
		t.Fatalf("a timetable with a real direction 1 changed: %v", two)
	}
	empty := &pb.Bus_DailyTimetables{}
	splitDailyAtTurnaround(empty, 2)
	if len(empty.Direction) != 0 {
		t.Fatalf("an empty timetable grew directions: %v", empty)
	}
}

func TestBusDailySplitsAtStoredTurnaround(t *testing.T) {
	db, rc := transitTestServices(t)
	uid := fmt.Sprintf("quality-bus-turnaround-%d", os.Getpid())
	key := shared.BusDailyTimetableKey(uid)
	if _, err := db.Exec(t.Context(), `INSERT INTO bus_static(sub_route_uid, pb, turnaround_stop_sequence) VALUES($1, ''::bytea, 2)`, uid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.Exec(context.Background(), "DELETE FROM bus_static WHERE sub_route_uid=$1", uid)
		_ = rc.Del(context.Background(), key).Err()
	})
	data, err := proto.Marshal(&pb.Bus_DailyTimetables{Direction: map[int32]*pb.Bus_DirectionTimetable{0: {DailyTimetables: []*pb.Bus_DailyTimetable{loopTrip("t", 1, 2, 3)}}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := rc.Set(t.Context(), key, data, time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	server := NewBusRouteServer(db, rc, nil, nil)
	got, err := server.Daily(t.Context(), &pb.Bus_Ask_Route{SubRouteUID: uid})
	if err != nil {
		t.Fatal(err)
	}
	if back := got.Data.Direction[1]; back == nil || fmt.Sprint(sequences(back.DailyTimetables[0])) != "[2 3]" {
		t.Fatalf("daily = %v, want direction 1 from the turnaround", got.Data)
	}
	if seq := server.turnaroundSequence(t.Context(), uid+"-missing"); seq != 0 {
		t.Fatalf("unknown subroute turnaround = %d, want 0", seq)
	}
	canceled, cancel := context.WithCancel(t.Context())
	cancel()
	if seq := server.turnaroundSequence(canceled, uid); seq != 0 {
		t.Fatalf("failed lookup turnaround = %d, want 0", seq)
	}
}

func TestTurnaroundSequenceWithoutDatabase(t *testing.T) {
	if seq := NewBusRouteServer(nil, nil, nil, nil).turnaroundSequence(t.Context(), "TAO2610"); seq != 0 {
		t.Fatalf("turnaround without a database = %d, want 0", seq)
	}
}
