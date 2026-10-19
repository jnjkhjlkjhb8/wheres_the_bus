package rail

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func railTestServices(t *testing.T) (*pgxpool.Pool, *redis.Client) {
	t.Helper()
	dsn, addr := os.Getenv("DATABASE_URL"), os.Getenv("REDIS_TEST_ADDR")
	if dsn == "" || addr == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL and REDIS_TEST_ADDR required")
		}
		t.Skip("DATABASE_URL or REDIS_TEST_ADDR not set")
	}
	db, err := pgxpool.New(t.Context(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		deadline := time.Now().Add(5 * time.Second)
		for {
			borrowed := db.Stat().AcquiredConns()
			if borrowed == 0 {
				db.Close()
				return
			}
			if !time.Now().Before(deadline) {
				// Unclosed rows keep a lease even after context cancellation, so
				// pool Close would hide the failure by waiting forever.
				t.Errorf("rail fixture leaked %d database connections before pool cleanup", borrowed)
				return
			}
			// Pool health checks can briefly borrow idle connections too.
			time.Sleep(10 * time.Millisecond)
		}
	})
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	return db, rc
}

func TestRailHandlersReadCachedPayloads(t *testing.T) {
	db, rc := railTestServices(t)
	tra, thsr := NewTraTimetableServer(db, rc, nil), NewThsrServer(db, rc, nil)
	traTrain, thsrTrain := NewTraDetainServer(db, rc, nil), NewThsrDetainServer(db, rc, nil)
	origin, destination := strconv.Itoa(1_000_000_000+os.Getpid()), "999999999"
	date, train := "2026-10-10", "quality-"+strconv.Itoa(os.Getpid())
	tests := []struct {
		name string
		key  string
		want proto.Message
		load func(context.Context) (proto.Message, error)
	}{
		{"tra fare", "TRA_Fare:v2:" + origin + ":" + destination, &pb.TraFareItems{Items: []*pb.TraFareItem{{Price: 123}}},
			func(ctx context.Context) (proto.Message, error) {
				return tra.Fare(ctx, &pb.AskStaiton{StationId: origin, Date: destination})
			}},
		{"thsr fare", "THSR_Fare:v2:" + origin + ":" + destination, &pb.ThsaFares{Items: []*pb.ThsaFare{{Price: 456}}},
			func(ctx context.Context) (proto.Message, error) {
				return thsr.Fare(ctx, &pb.Ask_Thsr{OriginStationId: origin, DestinationStationId: destination})
			}},
		{"tra timetable", "TRA_timetable:" + date + ":" + origin + ":" + destination, &pb.TraTimetables{Items: []*pb.TraTimetable{{TrainNo: train}}},
			func(ctx context.Context) (proto.Message, error) {
				return tra.Timetable(ctx, &pb.AskRoute{OriginStationId: origin, DestinationStationId: destination, Date: date})
			}},
		{"thsr timetable", "THSR_timetable:" + date + ":" + origin + ":" + destination, &pb.ThsrTimetables{Items: []*pb.ThsaTimetable{{TrainNo: train}}},
			func(ctx context.Context) (proto.Message, error) {
				return thsr.Timetable(ctx, &pb.Ask_Thsr{OriginStationId: origin, DestinationStationId: destination, Date: date})
			}},
		{"tra stops", "TRA_Stoptimes:" + date + ":" + train, &pb.TraStoptimes{Items: []*pb.TraStoptime{{StationId: origin}}},
			func(ctx context.Context) (proto.Message, error) {
				return traTrain.Stops(ctx, &pb.AskDetain{Trainno: train, Date: date})
			}},
		{"thsr stops", "THSR_Stoptimes:" + date + ":" + train, &pb.ThsrStoptimes{Items: []*pb.ThsaStoptime{{StationId: origin}}},
			func(ctx context.Context) (proto.Message, error) {
				return thsrTrain.Stops(ctx, &pb.ThsrAskDetain{Trainno: train, Date: date})
			}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b, err := proto.Marshal(tt.want)
			if err != nil {
				t.Fatal(err)
			}
			if err := rc.Set(t.Context(), tt.key, b, time.Minute).Err(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = rc.Del(context.Background(), tt.key).Err() })
			got, err := tt.load(t.Context())
			if err != nil || !proto.Equal(got, tt.want) {
				t.Fatalf("cached response = %v, err %v, want %v", got, err, tt.want)
			}
			if err := rc.Set(t.Context(), tt.key, []byte{0xff}, time.Minute).Err(); err != nil {
				t.Fatal(err)
			}
			if _, err := tt.load(t.Context()); status.Code(err) != codes.Internal {
				t.Fatalf("corrupt payload error = %v, want Internal", err)
			}
			if err := rc.Del(t.Context(), tt.key).Err(); err != nil {
				t.Fatal(err)
			}
			if _, err := tt.load(t.Context()); status.Code(err) != codes.NotFound {
				t.Fatalf("unlanded response error = %v, want NotFound", err)
			}
		})
	}
}

func TestRailReadCacheLifetimeAndFailures(t *testing.T) {
	_, rc := railTestServices(t)
	key := fmt.Sprintf("quality:rail-read:%d", os.Getpid())
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err() })
	calls := 0
	load := func(context.Context) ([]byte, int, error) { calls++; return []byte("payload"), 1, nil }
	for range 2 {
		b, err := railRead(t.Context(), rc, "test", key, time.Minute, load)
		if err != nil || string(b) != "payload" {
			t.Fatalf("cache payload = %q, err %v", b, err)
		}
	}
	if calls != 1 {
		t.Fatalf("cached request loaded %d times", calls)
	}
	if ttl, err := rc.TTL(t.Context(), key).Result(); err != nil || ttl <= 0 || ttl > time.Minute {
		t.Fatalf("cache TTL = %v, err %v", ttl, err)
	}
	if err := rc.Del(t.Context(), key).Err(); err != nil {
		t.Fatal(err)
	}
	for _, result := range []struct {
		b []byte
		n int
	}{{[]byte("payload"), 0}, {nil, 1}} {
		b, err := railRead(t.Context(), rc, "test", key, time.Minute, func(context.Context) ([]byte, int, error) { return result.b, result.n, nil })
		if err != nil || b != nil {
			t.Fatalf("empty load returned %q, err %v", b, err)
		}
	}
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	b, err := railRead(t.Context(), rc, "test", key, time.Minute, load)
	if err != nil || string(b) != "payload" {
		t.Fatalf("failed cache suppressed database success: %q, err %v", b, err)
	}
}
