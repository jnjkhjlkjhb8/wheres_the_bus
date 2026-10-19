package rail

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestStationBoardHandlersFilterAndTopUpCachedDays(t *testing.T) {
	db, rc := railTestServices(t)
	station := fmt.Sprintf("quality-board-%d", os.Getpid())
	date := "2026-10-10"
	tra, thsr := NewTraTimetableServer(db, rc, nil), NewThsrServer(db, rc, nil)
	for _, tc := range []struct {
		name, prefix          string
		today, tomorrow, want proto.Message
		load                  func(string, string, string, int32) (proto.Message, error)
	}{
		{"tra", "TRA_StationBoard", &pb.TraStationBoard{Items: []*pb.TraStationDeparture{{TrainNo: "old", DepartureTime: "10:00"}, {TrainNo: "today", DepartureTime: "15:00"}}}, &pb.TraStationBoard{Items: []*pb.TraStationDeparture{{TrainNo: "tomorrow", DepartureTime: "07:00"}}}, &pb.TraStationBoard{Items: []*pb.TraStationDeparture{{TrainNo: "today", DepartureTime: "15:00"}, {TrainNo: "tomorrow", DepartureTime: "07:00"}}}, func(station, date, after string, limit int32) (proto.Message, error) {
			return tra.StationBoard(t.Context(), &pb.AskStationBoard{StationId: station, Date: date, After: after, Limit: limit})
		}},
		{"thsr", "THSR_StationBoard", &pb.ThsrStationBoard{Items: []*pb.ThsrStationDeparture{{TrainNo: "old", DepartureTime: "10:00"}, {TrainNo: "today", DepartureTime: "15:00"}}}, &pb.ThsrStationBoard{Items: []*pb.ThsrStationDeparture{{TrainNo: "tomorrow", DepartureTime: "07:00"}}}, &pb.ThsrStationBoard{Items: []*pb.ThsrStationDeparture{{TrainNo: "today", DepartureTime: "15:00"}, {TrainNo: "tomorrow", DepartureTime: "07:00"}}}, func(station, date, after string, limit int32) (proto.Message, error) {
			return thsr.StationBoard(t.Context(), &pb.ThsrAskStationBoard{StationId: station, Date: date, After: after, Limit: limit})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			keys := []string{tc.prefix + ":" + date + ":" + station + ":0", tc.prefix + ":2026-10-11:" + station + ":0"}
			t.Cleanup(func() { _ = rc.Del(context.Background(), keys...).Err() })
			for i, payload := range []proto.Message{tc.today, tc.tomorrow} {
				b, err := proto.Marshal(payload)
				if err != nil {
					t.Fatal(err)
				}
				if err := rc.Set(t.Context(), keys[i], b, time.Minute).Err(); err != nil {
					t.Fatal(err)
				}
			}
			got, err := tc.load(station, date, "11:00", 2)
			if err != nil || !proto.Equal(got, tc.want) {
				t.Fatalf("station board = %v, error %v", got, err)
			}
			for _, request := range [][2]string{{"", date}, {station, "bad-date"}} {
				if _, err := tc.load(request[0], request[1], "", 2); status.Code(err) != codes.InvalidArgument {
					t.Fatalf("invalid board request error = %v", err)
				}
			}
			if err := rc.Set(t.Context(), keys[0], []byte{0xff}, time.Minute).Err(); err != nil {
				t.Fatal(err)
			}
			if _, err := tc.load(station, date, "", 2); status.Code(err) != codes.Internal {
				t.Fatalf("corrupt board error = %v", err)
			}
			if err := rc.Del(t.Context(), keys...).Err(); err != nil {
				t.Fatal(err)
			}
			if _, err := tc.load(station, date, "", 2); status.Code(err) != codes.NotFound {
				t.Fatalf("unlanded station board error = %v", err)
			}
		})
	}
}
