package main

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bus"
	"github.com/redis/go-redis/v9"
	"google.golang.org/protobuf/proto"
)

func unavailableRedisClient() *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr:         "127.0.0.1:1",
		DialTimeout:  time.Millisecond,
		ReadTimeout:  time.Millisecond,
		WriteTimeout: time.Millisecond,
		MaxRetries:   0,
	})
}
func testRedisAddr() string {
	if addr := os.Getenv("REDIS_TEST_ADDR"); addr != "" {
		return addr
	}
	return "127.0.0.1:6379"
}

func dialTestRedis(t *testing.T) *redis.Client {
	t.Helper()
	rc := redis.NewClient(&redis.Options{
		Addr:        testRedisAddr(),
		DialTimeout: 200 * time.Millisecond,
		MaxRetries:  0,
	})
	if err := rc.Ping(t.Context()).Err(); err != nil {
		_ = rc.Close()
		if os.Getenv("REDIS_TEST_ADDR") != "" {
			t.Fatalf("REDIS_TEST_ADDR is set but Redis is not reachable at %s: %v", testRedisAddr(), err)
		}
		t.Skipf("Redis not reachable at %s: %v", testRedisAddr(), err)
	}
	return rc
}

func TestLoadBusDailyTimetableRejectsInvalidIdentityTimeOrDirection(t *testing.T) {
	tests := []struct {
		name string
		body string
		want string
	}{
		{
			name: "missing subroute",
			body: `[{"Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "SubRouteUID",
		},
		{
			name: "invalid direction",
			body: `[{"SubRouteUID":"KHH1","Direction":2,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "Direction",
		},
		{
			name: "missing direction",
			body: `[{"SubRouteUID":"KHH1","Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "Direction",
		},
		{
			name: "invalid arrival",
			body: `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"24:00","DepartureTime":"08:01"}]}]}]`,
			want: "ArrivalTime",
		},
		{
			name: "missing trip ID",
			body: `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "TripID",
		},
		{
			name: "empty stop times",
			body: `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[]}]}]`,
			want: "StopTimes",
		},
		{
			name: "zero stop sequence",
			body: `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":0,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "StopSequence",
		},
		{
			name: "stop sequence exceeds protobuf int32",
			body: `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":2147483648,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "StopSequence",
		},
		{
			name: "missing stop UID",
			body: `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "StopUID",
		},
		{
			name: "invalid departure",
			body: `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"xx"}]}]}]`,
			want: "DepartureTime",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rc := unavailableRedisClient()
			defer func() { _ = rc.Close() }()
			err := bus.LoadDailyTimetable(context.Background(), decodeInto(tt.body), nil, nil, rc, "Kaohsiung")
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("loadBusDailyTimetable error = %v, want %q", err, tt.want)
			}
		})
	}
}

func TestLoadBusDailyTimetableRejectsInvalidCanonicalIdentityBeforeRedis(t *testing.T) {
	tests := []struct {
		name string
		city string
		body string
		want string
	}{
		{
			name: "InterCity suffix canonicalizes to empty",
			city: "InterCity",
			body: `[{"SubRouteUID":"01","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "canonical SubRouteUID",
		},
		{
			name: "wrong city authority prefix",
			city: "Kaohsiung",
			body: `[{"SubRouteUID":"TPE1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`,
			want: "authority",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rc := unavailableRedisClient()
			defer func() { _ = rc.Close() }()
			err := bus.LoadDailyTimetable(context.Background(), decodeInto(tt.body), nil, nil, rc, tt.city)
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("loadBusDailyTimetable error = %v, want pre-Redis %q validation", err, tt.want)
			}
		})
	}
}

func TestLoadBusDailyTimetableMalformedSuffixWritesNoKeys(t *testing.T) {
	rc := dialTestRedis(t)
	defer func() { _ = rc.Close() }()
	const uid = "ZZ_TASK5_NO_PARTIAL"
	key := shared.BusDailyTimetableKey(uid)
	_ = rc.Del(context.Background(), key).Err()
	defer func() { _ = rc.Del(context.Background(), key).Err() }()

	body := `[
		{"SubRouteUID":"` + uid + `","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]},
		{"SubRouteUID":
	]`
	err := bus.LoadDailyTimetable(context.Background(), decodeInto(body), nil, nil, rc, "Kaohsiung")
	if err == nil || !errMentions(err, "element 1") {
		t.Fatalf("loadBusDailyTimetable error = %v, want wrapped element 1 decode error", err)
	}
	if exists := rc.Exists(context.Background(), key).Val(); exists != 0 {
		t.Fatalf("Redis key %s exists after malformed suffix", key)
	}
}

func TestLoadBusDailyTimetableReturnsPipelineError(t *testing.T) {
	rc := unavailableRedisClient()
	defer func() { _ = rc.Close() }()
	body := `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`
	err := bus.LoadDailyTimetable(context.Background(), decodeInto(body), nil, nil, rc, "Kaohsiung")
	if err == nil || !errMentions(err, "Redis transaction") {
		t.Fatalf("loadBusDailyTimetable error = %v, want wrapped Redis transaction error", err)
	}
}

func TestLoadBusDailyTimetableDuplicateTripPolicy(t *testing.T) {
	rc := dialTestRedis(t)
	defer func() { _ = rc.Close() }()
	key := shared.BusDailyTimetableKey("KHH1")
	_ = rc.Del(context.Background(), key).Err()
	defer func() { _ = rc.Del(context.Background(), key).Err() }()
	trip := `{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}`
	identical := `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[` + trip + `,` + trip + `]}]`
	if err := bus.LoadDailyTimetable(context.Background(), decodeInto(identical), nil, nil, rc, "Kaohsiung"); err != nil {
		t.Fatalf("identical duplicate: %v", err)
	}
	bytes, err := rc.Get(context.Background(), key).Bytes()
	if err != nil {
		t.Fatalf("read deduped timetable: %v", err)
	}
	var got models.Bus_DailyTimetables
	if err := proto.Unmarshal(bytes, &got); err != nil {
		t.Fatalf("unmarshal deduped timetable: %v", err)
	}
	if len(got.Direction[0].DailyTimetables) != 1 {
		t.Fatalf("daily timetables = %d, want one identical trip", len(got.Direction[0].DailyTimetables))
	}
	if stopUID := got.Direction[0].DailyTimetables[0].StopTimes[0].StopUID; stopUID != "S1" {
		t.Fatalf("persisted StopUID = %q, want S1", stopUID)
	}
	other := `{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S2","ArrivalTime":"08:00","DepartureTime":"08:01"}]}`
	divergent := `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[` + trip + `,` + other + `]}]`
	err = bus.LoadDailyTimetable(context.Background(), decodeInto(divergent), nil, nil, rc, "Kaohsiung")
	if err == nil || !errMentions(err, "quarantine ratio exceeded") {
		t.Fatalf("divergent duplicate error = %v, want quarantine ratio exceeded error", err)
	}
	after, err := rc.Get(context.Background(), key).Bytes()
	if err != nil {
		t.Fatalf("read timetable after rejected duplicate: %v", err)
	}
	if string(after) != string(bytes) {
		t.Fatal("divergent duplicate trip mutated Redis")
	}
}

func TestLoadBusDailyTimetableDuplicateStopSequencePolicy(t *testing.T) {
	rc := dialTestRedis(t)
	defer func() { _ = rc.Close() }()
	key := shared.BusDailyTimetableKey("KHH1")
	_ = rc.Del(context.Background(), key).Err()
	defer func() { _ = rc.Del(context.Background(), key).Err() }()
	stop := `{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}`
	identical := `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[` + stop + `,` + stop + `]}]}]`
	if err := bus.LoadDailyTimetable(context.Background(), decodeInto(identical), nil, nil, rc, "Kaohsiung"); err != nil {
		t.Fatalf("identical duplicate stop: %v", err)
	}
	before, err := rc.Get(context.Background(), key).Bytes()
	if err != nil {
		t.Fatalf("read deduped timetable: %v", err)
	}
	var got models.Bus_DailyTimetables
	if err := proto.Unmarshal(before, &got); err != nil {
		t.Fatalf("unmarshal deduped timetable: %v", err)
	}
	if stops := got.Direction[0].DailyTimetables[0].StopTimes; len(stops) != 1 {
		t.Fatalf("deduped stops = %+v, want one target stop", stops)
	}

	other := `{"StopSequence":1,"StopUID":"S2","ArrivalTime":"08:00","DepartureTime":"08:01"}`
	divergent := `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[` + stop + `,` + other + `]}]}]`
	err = bus.LoadDailyTimetable(context.Background(), decodeInto(divergent), nil, nil, rc, "Kaohsiung")
	if err == nil || !errMentions(err, "quarantine ratio exceeded") {
		t.Fatalf("divergent duplicate stop error = %v, want quarantine ratio exceeded", err)
	}
	after, err := rc.Get(context.Background(), key).Bytes()
	if err != nil {
		t.Fatalf("read timetable after rejected duplicate: %v", err)
	}
	if string(after) != string(before) {
		t.Fatal("divergent duplicate stop mutated Redis")
	}
}

func TestLoadBusDailyTimetableFiltersMisfiledDirectionTrips(t *testing.T) {
	rc := dialTestRedis(t)
	defer func() { _ = rc.Close() }()
	key := shared.BusDailyTimetableKey("KHH1")
	_ = rc.Del(context.Background(), key).Err()
	defer func() { _ = rc.Del(context.Background(), key).Err() }()

	src := &fakeLoadSource{
		json: map[string][]byte{
			"bus_stopofroute|Kaohsiung": []byte(`[
				{"SubRouteUID":"KHH1","Direction":0,"Stops":[
					{"StopSequence":1,"StopUID":"S1","StopName":{"Zh_tw":"醫院"}},
					{"StopSequence":2,"StopUID":"S9","StopName":{"Zh_tw":"轉運站"}}]},
				{"SubRouteUID":"KHH1","Direction":1,"Stops":[
					{"StopSequence":1,"StopUID":"S9B","StopName":{"Zh_tw":"轉運站"}},
					{"StopSequence":2,"StopUID":"S1B","StopName":{"Zh_tw":"醫院"}}]}
			]`),
		},
		fetched: time.Now(),
	}
	body := `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[
		{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]},
		{"TripID":"T2","StopTimes":[{"StopSequence":1,"StopUID":"S9B","ArrivalTime":"09:00","DepartureTime":"09:01"}]},
		{"TripID":"T3","StopTimes":[{"StopSequence":1,"StopUID":"S1B","ArrivalTime":"10:00","DepartureTime":"10:01"}]}
	]}]`
	if err := bus.LoadDailyTimetable(context.Background(), decodeInto(body), src, nil, rc, "Kaohsiung"); err != nil {
		t.Fatalf("loadBusDailyTimetable with origin filter: %v", err)
	}
	bytes, err := rc.Get(context.Background(), key).Bytes()
	if err != nil {
		t.Fatalf("read filtered timetable: %v", err)
	}
	var got models.Bus_DailyTimetables
	if err := proto.Unmarshal(bytes, &got); err != nil {
		t.Fatalf("unmarshal filtered timetable: %v", err)
	}
	var kept []string
	for _, trip := range got.Direction[0].DailyTimetables {
		kept = append(kept, trip.TripID)
	}
	if len(kept) != 2 || kept[0] != "T1" || kept[1] != "T3" {
		t.Fatalf("kept trips = %v, want [T1 T3] (T2 departs the opposite origin)", kept)
	}

	if err := bus.LoadDailyTimetable(context.Background(), decodeInto(body), nil, nil, rc, "Kaohsiung"); err != nil {
		t.Fatalf("loadBusDailyTimetable without src: %v", err)
	}
	bytes, err = rc.Get(context.Background(), key).Bytes()
	if err != nil {
		t.Fatalf("read unfiltered timetable: %v", err)
	}
	if err := proto.Unmarshal(bytes, &got); err != nil {
		t.Fatalf("unmarshal unfiltered timetable: %v", err)
	}
	if n := len(got.Direction[0].DailyTimetables); n != 3 {
		t.Fatalf("unfiltered trips = %d, want all 3 kept when StopOfRoute is unavailable", n)
	}
}

// blockingPipelineHook parks EXEC until release is closed, so a test can cancel
// the context while the pipeline is mid-flight. Only the pipeline hook is
// interesting; dial and single-command processing pass straight through.
type blockingPipelineHook struct {
	entered chan struct{}
	release chan struct{}
}

func (blockingPipelineHook) DialHook(next redis.DialHook) redis.DialHook { return next }

func (blockingPipelineHook) ProcessHook(next redis.ProcessHook) redis.ProcessHook { return next }

func (h blockingPipelineHook) ProcessPipelineHook(_ redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return func(_ context.Context, _ []redis.Cmder) error {
		close(h.entered)
		<-h.release
		return nil
	}
}

func TestLoadBusDailyTimetableObservesCancellationDuringRedisExec(t *testing.T) {
	rc := unavailableRedisClient()
	defer func() { _ = rc.Close() }()
	entered := make(chan struct{})
	release := make(chan struct{})
	rc.AddHook(blockingPipelineHook{entered: entered, release: release})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	body := `[{"SubRouteUID":"KHH1","Direction":0,"Timetables":[{"TripID":"T1","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`
	go func() {
		done <- bus.LoadDailyTimetable(ctx, decodeInto(body), nil, nil, rc, "Kaohsiung")
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("Redis Exec was not entered")
	}
	if err := ctx.Err(); err != nil {
		t.Fatalf("context canceled before Redis Exec: %v", err)
	}
	cancel()
	close(release)
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) || !errMentions(err, "context during Redis transaction") {
			t.Fatalf("loadBusDailyTimetable error = %v, want wrapped in-Exec cancellation", err)
		}
	case <-time.After(time.Second):
		t.Fatal("loadBusDailyTimetable did not return after Redis Exec release")
	}
}
