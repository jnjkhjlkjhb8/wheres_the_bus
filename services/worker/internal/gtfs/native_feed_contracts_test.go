package gtfs

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	bindings "github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/protobuf/proto"
)

func rtFeedContractLogs(t *testing.T) *observer.ObservedLogs {
	t.Helper()
	core, logs := observer.New(zapcore.DebugLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	return logs
}

func rtFeedContractDB(t *testing.T, ids ...string) (context.Context, *pgxpool.Pool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	t.Cleanup(cancel)
	db := nativeGTFSIndexDB(t)
	if _, err := db.Exec(ctx, "INSERT INTO static_release VALUES('native-feed',1)"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		if _, err := db.Exec(ctx, "INSERT INTO gtfs_rt_bus_trip VALUES('native-feed',$1,0,'W:1111111')", id); err != nil {
			t.Fatal(err)
		}
	}
	return ctx, db
}

func rtFeedContractUID() string                 { return fmt.Sprintf("QRTnative%d", time.Now().UnixNano()) }
func rtFeedContractID(uid, clock string) string { return uid + ":0:" + clock + ":W:1111111" }

func rtFeedContractPut(t *testing.T, ctx context.Context, rc *redis.Client, key string, value proto.Message) {
	t.Helper()
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = rc.Del(cleanup, key).Err()
	})
	if err := rc.Set(ctx, key, mustGTFSPayload(t, value), time.Hour).Err(); err != nil {
		t.Fatal(err)
	}
}

func rtFeedContractRun(t *testing.T, ctx context.Context, b *gtfsRTBuilder, rc *redis.Client) *bindings.FeedMessage {
	t.Helper()
	now := busTestMidnight().Add(9 * time.Hour)
	if err := b.Run(ctx, now); err != nil {
		t.Fatal(err)
	}
	raw, err := rc.Get(ctx, shared.GTFSRealtimeKey()).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	feed := new(bindings.FeedMessage)
	if err := proto.Unmarshal(raw, feed); err != nil {
		t.Fatal(err)
	}
	if feed.Header.GetTimestamp() != uint64(now.Unix()) || feed.Header.GetIncrementality() != bindings.FeedHeader_FULL_DATASET {
		t.Fatalf("published feed header=%v", feed.Header)
	}
	return feed
}

func rtFeedContractOffsets(t *testing.T, ctx context.Context, db *pgxpool.Pool, uid string, offsets ...int64) {
	t.Helper()
	for i, offset := range offsets {
		if _, err := db.Exec(ctx, "INSERT INTO gtfs_rt_bus_offset VALUES('native-feed',$1,0,$2,$3)", uid, fmt.Sprintf("S%d", i+1), offset); err != nil {
			t.Fatal(err)
		}
	}
}

func rtFeedContractArrival(uid, plate string, projections, offsets []int64) *models.Bus_RouteArrival {
	arrival := &models.Bus_RouteArrival{SubRouteUid: uid}
	for i, projection := range projections {
		arrival.Stops = append(arrival.Stops, &models.Bus_RouteEstimate{StopUid: fmt.Sprintf("S%d", i+1), StopSequence: int32(i + 1), PlateNumb: plate, ArrivalUnix: projection + offsets[i]})
	}
	return arrival
}

func rtFeedContractCount(t *testing.T, logs *observer.ObservedLogs, action, field string, want int64) {
	t.Helper()
	found := false
	for _, entry := range logs.All() {
		fields := entry.ContextMap()
		if fields["component"] != "gtfs_rt" || fields["action"] != action {
			continue
		}
		if value, ok := fields[field]; ok {
			if value != want {
				t.Fatalf("%s %s=%v want %d", action, field, value, want)
			}
			found = true
		}
	}
	if !found {
		t.Fatalf("published %s coverage counter %s absent", action, field)
	}
}

func TestGTFSFeedNativePublicationFailureRetainsRedisCause(t *testing.T) {
	logs := rtFeedContractLogs(t)
	uid := rtFeedContractUID()
	ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"))
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	t.Cleanup(func() { _ = rc.Close() })
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	if err := NewRTBuilder(db, rc).Run(ctx, busTestMidnight()); !errors.Is(err, redis.ErrClosed) {
		t.Fatalf("failed publication cause=%v", err)
	}
	for _, entry := range logs.All() {
		if entry.ContextMap()["component"] == "gtfs_rt" && entry.ContextMap()["event"] == "success" {
			t.Fatal("failed feed publication reported success")
		}
	}
}

func TestGTFSFeedNativeMissingReleaseKeepsLastGoodIndex(t *testing.T) {
	uid := rtFeedContractUID()
	ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"), rtFeedContractID(uid, "1000"))
	rc := nativeGTFSRedis(t)
	rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "09:00"))
	b := NewRTBuilder(db, rc)
	first := rtFeedContractRun(t, ctx, b, rc)
	if len(first.Entity) != 1 || first.Entity[0].GetId() != rtFeedContractID(uid, "1000") {
		t.Fatalf("first feed=%v", first)
	}
	if _, err := db.Exec(ctx, "TRUNCATE static_release"); err != nil {
		t.Fatal(err)
	}
	second := rtFeedContractRun(t, ctx, b, rc)
	if !proto.Equal(first, second) {
		t.Fatal("temporary missing release discarded last-good published index")
	}
}

func TestGTFSFeedNativeMinute59AndDeparturePreference(t *testing.T) {
	for _, test := range []struct{ name, departure, arrival string }{
		{"explicit departure", "09:59", "07:00"},
		{"blank departure falls back", "   ", "09:59"},
	} {
		t.Run(test.name, func(t *testing.T) {
			logs := rtFeedContractLogs(t)
			uid := rtFeedContractUID()
			ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0959"), rtFeedContractID(uid, "1010"))
			rc := nativeGTFSRedis(t)
			daily := &models.Bus_DailyTimetables{SubRouteUID: uid, Direction: map[int32]*models.Bus_DirectionTimetable{0: {DailyTimetables: []*models.Bus_DailyTimetable{{StopTimes: []*models.Bus_StopTime{{StopSequence: 1, DepartureTime: test.departure, ArrivalTime: test.arrival}}}}}}}
			rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), daily)
			feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
			if len(feed.Entity) != 1 || feed.Entity[0].GetId() != rtFeedContractID(uid, "1010") || feed.Entity[0].GetTripUpdate().GetTrip().GetScheduleRelationship() != bindings.TripDescriptor_CANCELED {
				t.Fatalf("valid minute59 departure canceled incorrectly: %v", feed)
			}
			rtFeedContractCount(t, logs, "build", "routes_considered", 1)
		})
	}
}

func TestGTFSFeedNativeUnreadableDepartureCannotProveCancellation(t *testing.T) {
	logs := rtFeedContractLogs(t)
	uid := rtFeedContractUID()
	ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0001"), rtFeedContractID(uid, "0010"))
	rc := nativeGTFSRedis(t)
	rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "unreadable"))
	feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
	if len(feed.Entity) != 0 {
		t.Fatalf("unreadable departure invented cancellations: %v", feed.Entity)
	}
	rtFeedContractCount(t, logs, "build", "routes_gate_failed", 1)
}

func TestGTFSFeedNativeLowerMedianAndOffsetProjectionNameTheRightTrip(t *testing.T) {
	for _, test := range []struct {
		name        string
		offsets     []int64
		projections []int64
		want        string
	}{
		{"lower median of four", []int64{0, 60, 120, 180}, []int64{atClock(8, 0), atClock(9, 0), atClock(10, 0), atClock(11, 0)}, "0900"},
		{"subtract running offsets", []int64{900, 2700}, []int64{atClock(9, 0), atClock(9, 0)}, "0900"},
	} {
		t.Run(test.name, func(t *testing.T) {
			uid := rtFeedContractUID()
			ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0800"), rtFeedContractID(uid, "0900"), rtFeedContractID(uid, "1000"), rtFeedContractID(uid, "1100"))
			rc := nativeGTFSRedis(t)
			rtFeedContractOffsets(t, ctx, db, uid, test.offsets...)
			rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "08:00", "09:00", "10:00", "11:00"))
			rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(uid), rtFeedContractArrival(uid, "owned-vehicle", test.projections, test.offsets))
			feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
			if len(feed.Entity) != 1 || feed.Entity[0].GetId() != rtFeedContractID(uid, test.want) || feed.Entity[0].GetTripUpdate().GetVehicle().GetId() != "owned-vehicle" {
				t.Fatalf("wrong departure assignment: %v", feed.Entity)
			}
			calls := feed.Entity[0].GetTripUpdate().GetStopTimeUpdate()
			if len(calls) != len(test.offsets) {
				t.Fatalf("published calls=%d", len(calls))
			}
			for i, call := range calls {
				if call.GetStopId() != fmt.Sprintf("S%d", i+1) || call.GetArrival().GetTime() != test.projections[i]+test.offsets[i] {
					t.Fatalf("published call %d=%v", i, call)
				}
			}
		})
	}
}

func TestGTFSFeedNativeMatchingWindowIncludesBothEndpoints(t *testing.T) {
	for _, test := range []struct {
		name      string
		projected int64
	}{{"twenty minutes early", atClock(8, 40)}, {"twenty minutes late", atClock(9, 20)}} {
		t.Run(test.name, func(t *testing.T) {
			uid := rtFeedContractUID()
			ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"))
			rc := nativeGTFSRedis(t)
			offsets := []int64{0, 60}
			rtFeedContractOffsets(t, ctx, db, uid, offsets...)
			rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "09:00"))
			rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(uid), rtFeedContractArrival(uid, "owned-endpoint", []int64{test.projected, test.projected}, offsets))
			feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
			if len(feed.Entity) != 1 || feed.Entity[0].GetTripUpdate().GetVehicle().GetId() != "owned-endpoint" {
				t.Fatalf("window endpoint discarded: %v", feed.Entity)
			}
		})
	}
}

func TestGTFSFeedNativeTooEarlyVehicleDoesNotBlockLaterMatch(t *testing.T) {
	logs := rtFeedContractLogs(t)
	uid := rtFeedContractUID()
	ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"))
	rc := nativeGTFSRedis(t)
	offsets := []int64{0, 60}
	rtFeedContractOffsets(t, ctx, db, uid, offsets...)
	rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "09:00"))
	first := rtFeedContractArrival(uid, "owned-too-early", []int64{atClock(7, 0), atClock(7, 0)}, offsets)
	later := rtFeedContractArrival(uid, "owned-matched", []int64{atClock(9, 0), atClock(9, 0)}, offsets)
	first.Stops = append(first.Stops, later.Stops...)
	rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(uid), first)
	feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
	if len(feed.Entity) != 1 || feed.Entity[0].GetTripUpdate().GetVehicle().GetId() != "owned-matched" {
		t.Fatalf("early vehicle blocked the usable one: %v", feed.Entity)
	}
	rtFeedContractCount(t, logs, "bus_delay", "unmatched", 1)
	rtFeedContractCount(t, logs, "bus_delay", "matched", 1)
}

func TestGTFSFeedNativeEquidistantVehicleKeepsEarlierDeparture(t *testing.T) {
	uid := rtFeedContractUID()
	ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"), rtFeedContractID(uid, "0910"))
	rc := nativeGTFSRedis(t)
	offsets := []int64{0, 60}
	rtFeedContractOffsets(t, ctx, db, uid, offsets...)
	rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "09:00", "09:10"))
	rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(uid), rtFeedContractArrival(uid, "owned-tie", []int64{atClock(9, 5), atClock(9, 5)}, offsets))
	feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
	if len(feed.Entity) != 1 || feed.Entity[0].GetId() != rtFeedContractID(uid, "0900") {
		t.Fatalf("equal-distance assignment=%v", feed.Entity)
	}
}

func TestGTFSFeedNativeExact256RoutesPublishWithoutEmptyReads(t *testing.T) {
	logs := rtFeedContractLogs(t)
	ctx, db := rtFeedContractDB(t)
	rc := nativeGTFSRedis(t)
	existing, err := rc.Keys(ctx, shared.BusRouteEtaPattern("")).Result()
	if err != nil {
		t.Fatal(err)
	}
	if len(existing) != 0 {
		t.Fatal("dedicated Redis fixture contains foreign route arrival keys")
	}
	prefix := rtFeedContractUID()
	for i := range 256 {
		uid := fmt.Sprintf("%s_%03d", prefix, i)
		if _, err := db.Exec(ctx, "INSERT INTO gtfs_rt_bus_trip VALUES('native-feed',$1,0,'W:1111111')", rtFeedContractID(uid, "0900")); err != nil {
			t.Fatal(err)
		}
		rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "09:00"))
		rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(uid), &models.Bus_RouteArrival{SubRouteUid: uid})
	}
	feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
	if len(feed.Entity) != 0 {
		t.Fatalf("identical daily snapshot invented cancellations: %v", feed.Entity)
	}
	rtFeedContractCount(t, logs, "build", "routes_considered", 256)
	for _, entry := range logs.All() {
		if entry.ContextMap()["component"] == "gtfs_rt" && entry.Level >= zapcore.WarnLevel {
			t.Fatalf("complete exact-size snapshots reported failure: %s", entry.Message)
		}
	}
}

func TestGTFSFeedNativeUnorderedRoutesPublishSortedVehicleEntities(t *testing.T) {
	uid := rtFeedContractUID()
	a, z := uid+"A", uid+"Z"
	ctx, db := rtFeedContractDB(t, rtFeedContractID(z, "0900"), rtFeedContractID(a, "0900"))
	rc := nativeGTFSRedis(t)
	for _, route := range []string{z, a} {
		offsets := []int64{0, 60}
		rtFeedContractOffsets(t, ctx, db, route, offsets...)
		rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(route), gtfsRTDaily(route, 0, "09:00"))
		rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(route), rtFeedContractArrival(route, route+"-plate", []int64{atClock(9, 0), atClock(9, 0)}, offsets))
	}
	feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
	got := make([]string, 0, len(feed.Entity))
	for _, entity := range feed.Entity {
		got = append(got, entity.GetId())
	}
	want := []string{rtFeedContractID(a, "0900"), rtFeedContractID(z, "0900")}
	if !slices.Equal(got, want) {
		t.Fatalf("published sorted IDs=%v want %v", got, want)
	}
}

func TestGTFSFeedNativeStaticScanFailureCannotPublishPartialIndex(t *testing.T) {
	for _, test := range []struct{ name, statement string }{
		{"bus direction", "INSERT INTO gtfs_rt_bus_trip VALUES('native-feed','unused',NULL,'W:1111111')"},
		{"rail station array", "INSERT INTO gtfs_rt_rail_trip VALUES('native-feed','2026-08-07','owned','owned',ARRAY[NULL]::text[])"},
		{"offset direction", "INSERT INTO gtfs_rt_bus_offset VALUES('native-feed','owned',NULL,'S1',0)"},
	} {
		t.Run(test.name, func(t *testing.T) {
			uid := rtFeedContractUID()
			ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"))
			rc := nativeGTFSRedis(t)
			if _, err := db.Exec(ctx, test.statement); err != nil {
				t.Fatal(err)
			}
			previous := []byte("owned-last-good-feed")
			if err := rc.Set(ctx, shared.GTFSRealtimeKey(), previous, time.Hour).Err(); err != nil {
				t.Fatal(err)
			}
			err := NewRTBuilder(db, rc).Run(ctx, busTestMidnight().Add(9*time.Hour))
			var scanErr pgx.ScanArgError
			if !errors.As(err, &scanErr) {
				t.Fatalf("partial index lost original scan failure: %v", err)
			}
			got, getErr := rc.Get(ctx, shared.GTFSRealtimeKey()).Bytes()
			if getErr != nil || !slices.Equal(got, previous) {
				t.Fatalf("failed partial index overwrote previous feed: %v %v", got, getErr)
			}
		})
	}
}

func TestGTFSFeedNativeOffsetStreamFailureRetainsSQLCause(t *testing.T) {
	uid := rtFeedContractUID()
	ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"))
	rc := nativeGTFSRedis(t)
	if _, err := db.Exec(ctx, `DROP TABLE gtfs_rt_bus_offset;
 CREATE FUNCTION native_offset_value(n integer) RETURNS bigint LANGUAGE plpgsql VOLATILE AS $$ BEGIN IF n=2000 THEN RAISE EXCEPTION 'owned offset stream failed' USING ERRCODE='22012'; END IF; RETURN n; END $$;
 CREATE VIEW gtfs_rt_bus_offset AS SELECT 'native-feed'::text AS run_id,'owned'::text AS sub_route_uid,0::int AS direction,('S'||n)::text AS stop_uid,native_offset_value(n) AS offset_secs FROM generate_series(1,2000) n;`); err != nil {
		t.Fatal(err)
	}
	err := NewRTBuilder(db, rc).Run(ctx, busTestMidnight().Add(9*time.Hour))
	var databaseErr *pgconn.PgError
	if !errors.As(err, &databaseErr) || databaseErr.Code != "22012" {
		t.Fatalf("stream failure lost SQL cause: %v", err)
	}
}

func TestGTFSFeedNativeMissingArrivalDoesNotInventAStopUpdate(t *testing.T) {
	uid := rtFeedContractUID()
	ctx, db := rtFeedContractDB(t, rtFeedContractID(uid, "0900"))
	rc := nativeGTFSRedis(t)
	offsets := []int64{0, 60, 120}
	rtFeedContractOffsets(t, ctx, db, uid, offsets...)
	rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), gtfsRTDaily(uid, 0, "09:00"))
	arrival := rtFeedContractArrival(uid, "owned-missing-arrival", []int64{atClock(9, 0), atClock(9, 0), 0}, offsets)
	arrival.Stops[2].ArrivalUnix = 0
	rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(uid), arrival)
	feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
	if len(feed.Entity) != 1 {
		t.Fatalf("valid vehicle was discarded: %v", feed.Entity)
	}
	calls := feed.Entity[0].GetTripUpdate().GetStopTimeUpdate()
	if len(calls) != 2 || calls[0].GetStopId() != "S1" || calls[1].GetStopId() != "S2" {
		t.Fatalf("missing arrival invented a stop update: %v", calls)
	}
}

func TestGTFSFeedNativeBothDirectionsRemainDistinctInPublication(t *testing.T) {
	uid := rtFeedContractUID()
	outbound := rtFeedContractID(uid, "0900")
	inbound := uid + ":1:0900:W:1111111"
	ctx, db := rtFeedContractDB(t, outbound)
	rc := nativeGTFSRedis(t)
	if _, err := db.Exec(ctx, "INSERT INTO gtfs_rt_bus_trip VALUES('native-feed',$1,1,'W:1111111')", inbound); err != nil {
		t.Fatal(err)
	}
	for _, direction := range []int32{0, 1} {
		for i, offset := range []int64{0, 60} {
			if _, err := db.Exec(ctx, "INSERT INTO gtfs_rt_bus_offset VALUES('native-feed',$1,$2,$3,$4)", uid, direction, fmt.Sprintf("S%d", i+1), offset); err != nil {
				t.Fatal(err)
			}
		}
	}
	daily := gtfsRTDaily(uid, 0, "09:00")
	daily.Direction[1] = gtfsRTDaily(uid, 1, "09:00").Direction[1]
	rtFeedContractPut(t, ctx, rc, shared.BusDailyTimetableKey(uid), daily)
	arrival := rtFeedContractArrival(uid, "owned-outbound", []int64{atClock(9, 0), atClock(9, 0)}, []int64{0, 60})
	other := rtFeedContractArrival(uid, "owned-inbound", []int64{atClock(9, 0), atClock(9, 0)}, []int64{0, 60})
	for _, stop := range other.Stops {
		stop.Direction = 1
	}
	arrival.Stops = append(arrival.Stops, other.Stops...)
	rtFeedContractPut(t, ctx, rc, shared.BusRouteEtaKey(uid), arrival)
	feed := rtFeedContractRun(t, ctx, NewRTBuilder(db, rc), rc)
	if len(feed.Entity) != 2 || feed.Entity[0].GetId() != outbound || feed.Entity[1].GetId() != inbound || feed.Entity[0].GetTripUpdate().GetVehicle().GetId() != "owned-outbound" || feed.Entity[1].GetTripUpdate().GetVehicle().GetId() != "owned-inbound" {
		t.Fatalf("direction publication lost identity: %v", feed.Entity)
	}
}
