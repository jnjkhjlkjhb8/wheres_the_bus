package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/protobuf/proto"
)

func TestLoadBusDailyTimetableAcceptsReturnDirectionAndSequenceEndpoints(t *testing.T) {
	for _, tc := range []struct {
		name     string
		sequence int64
		want     string
	}{
		{"first sequence", 1, "nil client"},
		{"maximum sequence", 2147483647, "nil client"},
		{"zero sequence", 0, "StopSequence out of range"},
		{"sequence overflow", 2147483648, "StopSequence out of range"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := fmt.Sprintf(`[{"SubRouteUID":"KHH_CONTRACT_ENDPOINTS","Direction":1,"Timetables":[{"TripID":"return","StopTimes":[{"StopSequence":%d,"StopUID":"terminal","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`, tc.sequence)
			err := bus.LoadDailyTimetable(t.Context(), decodeInto(body), nil, nil, nil, "Kaohsiung")
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("public load sequence %d error = %v, want %q", tc.sequence, err, tc.want)
			}
		})
	}
}

func TestLoadBusDailyTimetableReturnTripsUseEarliestStopAndReportDroppedTrips(t *testing.T) {
	rc := dialTestRedis(t)
	t.Cleanup(func() { _ = rc.Close() })
	const uid = "KHH_CONTRACT_RETURN"
	key := shared.BusDailyTimetableKey(uid)
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err() })
	core, observed := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	src := &fakeLoadSource{json: map[string][]byte{
		"bus_stopofroute|Kaohsiung": []byte(`[
		{"SubRouteUID":"KHH_CONTRACT_RETURN","Direction":0,"Stops":[
		{"StopSequence":1,"StopUID":"A","StopName":{"Zh_tw":"醫院"}},
		{"StopSequence":2,"StopUID":"B_ALIAS","StopName":{"Zh_tw":"轉運站"}}]},
		{"SubRouteUID":"KHH_CONTRACT_RETURN","Direction":1,"Stops":[
		{"StopSequence":1,"StopUID":"B","StopName":{"Zh_tw":"轉運站"}},
		{"StopSequence":2,"StopUID":"A_ALIAS","StopName":{"Zh_tw":"醫院"}}]}]`),
	}, fetched: time.Date(2026, 10, 11, 0, 0, 0, 0, time.UTC)}
	body := `[{"SubRouteUID":"KHH_CONTRACT_RETURN","Direction":1,"Timetables":[
	{"TripID":"correct","StopTimes":[{"StopSequence":2,"StopUID":"A_ALIAS","ArrivalTime":"08:20","DepartureTime":"08:21"},{"StopSequence":1,"StopUID":"B","ArrivalTime":"08:00","DepartureTime":"08:01"}]},
	{"TripID":"wrong-first","StopTimes":[{"StopSequence":1,"StopUID":"A_ALIAS","ArrivalTime":"09:00","DepartureTime":"09:01"},{"StopSequence":2,"StopUID":"B","ArrivalTime":"09:20","DepartureTime":"09:21"}]},
	{"TripID":"same-origin-name","StopTimes":[{"StopSequence":1,"StopUID":"B_ALIAS","ArrivalTime":"10:00","DepartureTime":"10:01"}]},
	{"TripID":"wrong-second","StopTimes":[{"StopSequence":1,"StopUID":"A","ArrivalTime":"11:00","DepartureTime":"11:01"}]}]}]`
	if err := bus.LoadDailyTimetable(t.Context(), decodeInto(body), src, nil, rc, "Kaohsiung"); err != nil {
		t.Fatal(err)
	}
	payload, err := rc.Get(t.Context(), key).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	var got models.Bus_DailyTimetables
	if err := proto.Unmarshal(payload, &got); err != nil {
		t.Fatal(err)
	}
	if got.Direction[1] == nil {
		t.Fatalf("return direction missing: %v", &got)
	}
	trips := got.Direction[1].GetDailyTimetables()
	if got.SubRouteUID != uid || len(trips) != 2 || trips[0].TripID != "correct" || trips[1].TripID != "same-origin-name" {
		t.Fatalf("return timetable = %v, want correct and same-origin-name in source order", &got)
	}
	logs := observed.FilterField(zap.String("event", "misfiled_direction_trips")).All()
	if len(logs) != 1 {
		t.Fatalf("misfiled reports = %d, want one", len(logs))
	}
	fields := logs[0].ContextMap()
	if fields["city"] != "Kaohsiung" || fields["dropped"] != int64(2) || fields["first"] != "TripID_'wrong-first'_for_KHH_CONTRACT_RETURN/1_departs_A_ALIAS" {
		t.Fatalf("misfiled report = %v, want city, two drops, and first rejected trip", fields)
	}
}

func TestLoadBusDailyTimetableValidTripsDoNotEmitMisfiledReport(t *testing.T) {
	rc := dialTestRedis(t)
	t.Cleanup(func() { _ = rc.Close() })
	key := shared.BusDailyTimetableKey("KHH_CONTRACT_NO_DROPS")
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err() })
	core, observed := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	body := `[{"SubRouteUID":"KHH_CONTRACT_NO_DROPS","Direction":0,"Timetables":[{"TripID":"accepted","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`
	if err := bus.LoadDailyTimetable(t.Context(), decodeInto(body), nil, nil, rc, "Kaohsiung"); err != nil {
		t.Fatal(err)
	}
	if _, err := rc.Get(t.Context(), key).Bytes(); err != nil {
		t.Fatalf("published valid trip: %v", err)
	}
	if logs := observed.FilterField(zap.String("event", "misfiled_direction_trips")).All(); len(logs) != 0 {
		t.Fatalf("valid trips emitted %d misfiled reports", len(logs))
	}
}

func TestLoadBusDailyTimetablePreservesCancellationBeforeClientFailure(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	body := `[{"SubRouteUID":"KHH_CONTRACT_CANCEL","Direction":0,"Timetables":[{"TripID":"accepted","StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`
	if err := bus.LoadDailyTimetable(ctx, decodeInto(body), nil, nil, nil, "Kaohsiung"); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled public load error = %v, want context.Canceled", err)
	}
}
