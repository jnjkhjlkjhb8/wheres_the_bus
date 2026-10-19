package bus

import (
	"bytes"
	"fmt"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/protobuf/proto"
)

func contractSnapshot(t *testing.T, src *busSnapshotSource, city string) *busCitySnapshot {
	t.Helper()
	snapshot, err := readBusCitySnapshot(t.Context(), src, city)
	if err != nil {
		t.Fatalf("assemble %s snapshot: %v", city, err)
	}
	if snapshot == nil {
		t.Fatal("snapshot is nil")
	}
	return snapshot
}

func contractPublishedSubroutes(t *testing.T, snapshot *busCitySnapshot) map[string]*models.BusSubroute {
	t.Helper()
	published := make(map[string]*models.BusSubroute, len(snapshot.staticRows))
	for _, row := range snapshot.staticRows {
		if len(row) != 8 {
			t.Fatalf("static persistence row has %d fields, want 8", len(row))
		}
		payload, ok := row[7].([]byte)
		if !ok {
			t.Fatalf("static payload type = %T, want []byte", row[7])
		}
		var sub models.BusSubroute
		if err := proto.Unmarshal(payload, &sub); err != nil {
			t.Fatalf("decode static persistence payload: %v", err)
		}
		if published[sub.SubRouteUID] != nil {
			t.Fatalf("duplicate published subroute %q", sub.SubRouteUID)
		}
		published[sub.SubRouteUID] = &sub
	}
	return published
}

func TestSnapshotContractPublishesEverySubrouteDirectionAndMergedOperator(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_operator|Taipei"] = []byte(`[{"OperatorID":"OP2","OperatorName":{"Zh_tw":"乙客運"},"AuthorityCode":"TPE"},{"OperatorID":"OP1","OperatorName":{"Zh_tw":"甲客運"},"AuthorityCode":"TPE"}]`)
	src.bodies["bus_route|Taipei"] = []byte(`[
	{"RouteUID":"TPE1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":1,"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙"}]},
	{"RouteUID":"TPE1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"OP1"},{"OperatorID":"OP2"}],"SubRoutes":[{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":0,"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙"},{"SubRouteUID":"TPE200","SubRouteID":"200","SubRouteName":{"Zh_tw":"支線"},"Direction":0,"DepartureStopNameZh":"丙","DestinationStopNameZh":"丁"}]}]`)
	src.bodies["bus_stopofroute|Taipei"] = []byte(`[
	{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[{"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25.0}}]},
	{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":1,"Stops":[{"StopUID":"TPE_S2","StopName":{"Zh_tw":"乙站"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25.0}}]},
	{"RouteUID":"TPE1","SubRouteUID":"TPE200","Direction":0,"Stops":[{"StopUID":"TPE_S3","StopName":{"Zh_tw":"丙站"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25.0}}]}]`)
	snapshot := contractSnapshot(t, src, "Taipei")
	published := contractPublishedSubroutes(t, snapshot)
	if len(published) != 2 || published["TPE100"] == nil || published["TPE200"] == nil {
		t.Fatalf("published subroutes = %v, want TPE100 and TPE200", published)
	}
	sub := published["TPE100"]
	if len(sub.Directions) != 2 || sub.Directions[0] == nil || sub.Directions[1] == nil {
		t.Fatalf("published directions = %v, want outbound and return", sub.Directions)
	}
	if sub.DepartureStopName != "甲" || sub.DestinationStopName != "乙" || sub.Directions[1].DepartureStopName != "乙" || sub.Directions[1].DestinationStopName != "甲" {
		t.Fatalf("published endpoints = %v, want outbound summary and reversed return endpoints", sub)
	}
	if len(sub.Operators) != 2 || sub.Operators[0].OperatorId != "OP1" || sub.Operators[1].OperatorId != "OP2" {
		t.Fatalf("published operators = %v, want OP1 and OP2 once each", sub.Operators)
	}
	want := []struct {
		uid       string
		direction int32
		stop      string
	}{
		{uid: "TPE100", direction: 0, stop: "TPE_S1"},
		{uid: "TPE100", direction: 1, stop: "TPE_S2"},
		{uid: "TPE200", direction: 0, stop: "TPE_S3"},
	}
	if len(snapshot.subrouteRows) != len(want) || len(snapshot.stopMapRows) != len(want) {
		t.Fatalf("direction rows = %d, stop map rows = %d, want three of each", len(snapshot.subrouteRows), len(snapshot.stopMapRows))
	}
	for i, expected := range want {
		row, stop := snapshot.subrouteRows[i], snapshot.stopMapRows[i]
		if row[0] != expected.uid || row[2] != expected.direction || stop[2] != expected.uid || stop[4] != expected.direction || stop[5] != expected.stop {
			t.Fatalf("persistence row %d = %v; stop row = %v; want %+v", i, row, stop, expected)
		}
	}
}

func TestSnapshotContractPublishesAllRecurringTripsAndHeadwayWindows(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_schedule|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Timetables":[
	{"TripID":"early","ServiceDay":{"Monday":1},"StopTimes":[{"StopSequence":32767,"StopUID":"TPE_END","StopName":{"Zh_tw":"終點"},"ArrivalTime":"07:00","DepartureTime":"07:01"},{"StopSequence":1,"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"ArrivalTime":"06:00","DepartureTime":"06:01"}]},
	{"TripID":"late","ServiceDay":{"Monday":1},"StopTimes":[{"StopSequence":1,"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"ArrivalTime":"08:00","DepartureTime":"08:01"}]}],
	"Frequencys":[{"StartTime":"09:00","EndTime":"12:00","MinHeadwayMins":10,"MaxHeadwayMins":10,"ServiceDay":{"Monday":1}},{"StartTime":"13:00","EndTime":"18:00","MinHeadwayMins":15,"MaxHeadwayMins":20,"ServiceDay":{"Monday":1}}]}]`)
	snapshot := contractSnapshot(t, src, "Taipei")
	published := contractPublishedSubroutes(t, snapshot)["TPE100"]
	if published == nil || published.Directions[0] == nil {
		t.Fatalf("published scheduled subroute = %v", published)
	}
	schedules := published.Directions[0].Schedules
	if len(schedules) != 4 || len(snapshot.scheduleRows) != 5 {
		t.Fatalf("wire schedules = %v, persistence rows = %v, want two trips and two windows", schedules, snapshot.scheduleRows)
	}
	if !schedules[0].IsTimetable || schedules[0].Tripid != "early" || schedules[0].MinHeadwayMinsArrivalTime != "06:00" || schedules[1].Tripid != "late" {
		t.Fatalf("published fixed trips = %v, want earliest stop for early and retained late trip", schedules[:2])
	}
	for i, expected := range []struct{ start, end, minimum, maximum string }{
		{start: "09:00", end: "12:00", minimum: "10", maximum: "10"},
		{start: "13:00", end: "18:00", minimum: "15", maximum: "20"},
	} {
		wire, row := schedules[i+2], snapshot.scheduleRows[i+3]
		if wire.IsTimetable || wire.Start_Time != expected.start || wire.End_Time != expected.end || wire.MinHeadwayMinsArrivalTime != expected.minimum || wire.MaxHeadwayMinsDepartureTime != expected.maximum {
			t.Fatalf("published window %d = %v, want %+v", i, wire, expected)
		}
		if row[2] != true || row[5] != int16(-1) || row[6] != expected.minimum || row[7] != expected.maximum || row[8] != expected.start || row[9] != expected.end {
			t.Fatalf("persisted window %d = %v, want frequency sentinel and %+v", i, row, expected)
		}
	}
	if snapshot.scheduleRows[0][5] != int16(32767) || snapshot.scheduleRows[1][5] != int16(1) {
		t.Fatalf("persisted timetable endpoints = %v, want sequences 32767 and 1", snapshot.scheduleRows[:2])
	}
}

func TestSnapshotContractQuarantinesInvalidScheduleWithoutPublishingPartialRows(t *testing.T) {
	for _, tc := range []struct{ name, content string }{
		{name: "zero sequence", content: `"Timetables":[{"TripID":"invalid","StopTimes":[{"StopSequence":0,"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"ArrivalTime":"08:00","DepartureTime":"08:01"}]}]`},
		{name: "sequence overflow", content: `"Timetables":[{"TripID":"invalid","StopTimes":[{"StopSequence":32768,"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"ArrivalTime":"08:00","DepartureTime":"08:01"}]}]`},
		{name: "zero headway", content: `"Frequencys":[{"StartTime":"09:00","EndTime":"12:00","MinHeadwayMins":0,"MaxHeadwayMins":10}]`},
		{name: "descending headway", content: `"Frequencys":[{"StartTime":"09:00","EndTime":"12:00","MinHeadwayMins":10,"MaxHeadwayMins":5}]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
			core, observed := observer.New(zap.WarnLevel)
			t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
			src := validBusSnapshotSource("Taipei")
			src.bodies["bus_schedule|Taipei"] = []byte(fmt.Sprintf(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,%s}]`, tc.content))
			snapshot := contractSnapshot(t, src, "Taipei")
			sub := contractPublishedSubroutes(t, snapshot)["TPE100"]
			if sub == nil || sub.Directions[0] == nil || len(sub.Directions[0].Schedules) != 0 || len(snapshot.scheduleRows) != 0 {
				t.Fatalf("quarantined schedule leaked into wire or persistence: subroute %v; rows %v", sub, snapshot.scheduleRows)
			}
			logs := observed.FilterField(zap.String("reason", "schedule_malformed")).All()
			if len(logs) != 1 || logs[0].ContextMap()["count"] != int64(1) {
				t.Fatalf("schedule quarantine reports = %v, want one dropped variant", logs)
			}
		})
	}
}

func TestSnapshotContractInvalidClockDigitsAreBlankOnPublishedRoute(t *testing.T) {
	for _, value := range []string{"39:00", "05:69"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
			src := validBusSnapshotSource("Taipei")
			src.bodies["bus_route|Taipei"] = bytes.Replace(src.bodies["bus_route|Taipei"], []byte(`"FirstBusTime":"06:00"`), []byte(fmt.Sprintf(`"FirstBusTime":%q`, value)), 1)
			sub := contractPublishedSubroutes(t, contractSnapshot(t, src, "Taipei"))["TPE100"]
			if sub == nil || sub.Directions[0] == nil || sub.Directions[0].FirstBusTime != "" || sub.Directions[0].LastBusTime != "23:00" {
				t.Fatalf("published invalid first clock %q = %v, want blank first and retained last", value, sub)
			}
		})
	}
}

func TestSnapshotContractMapsOpaqueNativeFareIDAndPreservesFarePayload(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_route|Taipei"] = bytes.Replace(src.bodies["bus_route|Taipei"], []byte(`"SubRouteID":"100"`), []byte(`"SubRouteID":"operator-specific"`), 1)
	src.bodies["bus_routefare|Taipei"] = []byte(`[{"SubRouteID":"operator-specific","FarePricingType":1,"IsFreeBus":1,"SectionFares":[{"Price":15}],"StageFares":null}]`)
	sub := contractPublishedSubroutes(t, contractSnapshot(t, src, "Taipei"))["TPE100"]
	if sub == nil || sub.Fare == nil || !sub.Fare.IsFreeBus || sub.Fare.FarePricingType != 1 || string(sub.Fare.SectionFaresJson) != `[{"Price":15}]` || len(sub.Fare.StageFaresJson) != 0 || len(sub.Fare.OdFaresJson) != 0 {
		t.Fatalf("published native fare = %v, want free fare with section JSON and absent/null optional JSON", sub)
	}
}

func TestSnapshotContractRouteWideFarePricesEveryCanonicalSubroute(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_route|Taipei"] = []byte(`[{"RouteUID":"TPE1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":0},{"SubRouteUID":"TPE200","SubRouteID":"200","SubRouteName":{"Zh_tw":"支線"},"Direction":0}]}]`)
	secondStops := bytes.Replace(src.bodies["bus_stopofroute|Taipei"], []byte(`"SubRouteUID":"TPE100"`), []byte(`"SubRouteUID":"TPE200"`), 1)
	src.bodies["bus_stopofroute|Taipei"] = append(append(append([]byte{}, src.bodies["bus_stopofroute|Taipei"][:len(src.bodies["bus_stopofroute|Taipei"])-1]...), ','), secondStops[1:]...)
	src.bodies["bus_routefare|Taipei"] = []byte(`[{"RouteID":"1","IsForAllSubRoutes":1,"FarePricingType":2,"IsFreeBus":0,"SectionFares":[{"Price":20}]}]`)
	published := contractPublishedSubroutes(t, contractSnapshot(t, src, "Taipei"))
	if len(published) != 2 {
		t.Fatalf("published subroutes = %v, want both route branches", published)
	}
	for _, uid := range []string{"TPE100", "TPE200"} {
		sub := published[uid]
		if sub == nil || sub.Fare == nil || sub.Fare.IsFreeBus || sub.Fare.FarePricingType != 2 || string(sub.Fare.SectionFaresJson) != `[{"Price":20}]` {
			t.Fatalf("published fare for %s = %v, want route-wide nonfree fare", uid, sub)
		}
	}
}

func TestSnapshotContractCanonicalInterCityFareCanUseRouteNumber(t *testing.T) {
	src := validBusSnapshotSource("InterCity")
	src.bodies["bus_route|InterCity"] = []byte(`[{"RouteUID":"THB0968","RouteName":{"Zh_tw":"國道客運"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[{"SubRouteUID":"THB096801","SubRouteID":"096801","SubRouteName":{"Zh_tw":"國道客運"},"Direction":0}]}]`)
	src.bodies["bus_stopofroute|InterCity"] = []byte(`[{"RouteUID":"THB0968","SubRouteUID":"THB096801","Direction":0,"Stops":[{"StopUID":"THB_S1","StopName":{"Zh_tw":"甲站"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25.0}}]}]`)
	src.bodies["bus_station|InterCity"] = bytes.Replace(src.bodies["bus_station|InterCity"], []byte(`"TPEST1"`), []byte(`"THBST1"`), 1)
	src.bodies["bus_routefare|InterCity"] = []byte(`[{"SubRouteID":"0968","FarePricingType":1,"IsFreeBus":1}]`)
	sub := contractPublishedSubroutes(t, contractSnapshot(t, src, "InterCity"))["THB0968"]
	if sub == nil || sub.Fare == nil || !sub.Fare.IsFreeBus || sub.Fare.FarePricingType != 1 {
		t.Fatalf("published canonical intercity fare = %v, want route-number fare on THB0968", sub)
	}
}

func TestSnapshotContractReportsUnsurveyedCountsWithoutDroppingTransitData(t *testing.T) {
	for _, tc := range []struct {
		name          string
		stop, station bool
	}{
		{name: "surveyed"},
		{name: "stop only", stop: true},
		{name: "station only", station: true},
		{name: "both", stop: true, station: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			core, observed := observer.New(zap.WarnLevel)
			t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
			src := validBusSnapshotSource("Taipei")
			position, unknown := []byte(`"PositionLon":121.5,"PositionLat":25.0`), []byte(`"PositionLon":0,"PositionLat":0`)
			wantStops, wantStations := int64(0), int64(0)
			if tc.stop {
				src.bodies["bus_stopofroute|Taipei"] = bytes.Replace(src.bodies["bus_stopofroute|Taipei"], position, unknown, 1)
				wantStops = 1
			}
			if tc.station {
				src.bodies["bus_station|Taipei"] = bytes.Replace(src.bodies["bus_station|Taipei"], position, unknown, 1)
				wantStations = 1
			}
			snapshot := contractSnapshot(t, src, "Taipei")
			sub := contractPublishedSubroutes(t, snapshot)["TPE100"]
			if sub == nil || sub.Directions[0] == nil || len(sub.Directions[0].Stops) != 1 || len(snapshot.stationRows) != 1 || len(snapshot.stopMapRows) != 1 {
				t.Fatalf("unsurveyed data was lost: published %v; stations %v; stops %v", sub, snapshot.stationRows, snapshot.stopMapRows)
			}
			logs := observed.FilterField(zap.String("event", "unsurveyed_positions")).All()
			if !tc.stop && !tc.station {
				if len(logs) != 0 {
					t.Fatalf("surveyed fixture emitted reports: %v", logs)
				}
				return
			}
			if len(logs) != 1 {
				t.Fatalf("unsurveyed reports = %v, want one city summary", logs)
			}
			fields := logs[0].ContextMap()
			if fields["city"] != "Taipei" || fields["stop_count"] != wantStops || fields["station_count"] != wantStations {
				t.Fatalf("unsurveyed summary = %v, want stop_count %d, station_count %d", fields, wantStops, wantStations)
			}
		})
	}
}

func TestSnapshotContractRetainsFirstGeometryWhenVariantsDiverge(t *testing.T) {
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_shape|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Geometry":"LINESTRING(121.5 25.0,121.6 25.1)"},{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Geometry":"LINESTRING(121.5 25.0,121.7 25.2)"}]`)
	snapshot := contractSnapshot(t, src, "Taipei")
	sub := contractPublishedSubroutes(t, snapshot)["TPE100"]
	if sub == nil || sub.Directions[0] == nil || sub.Directions[0].Geometry != "LINESTRING(121.5 25.0,121.6 25.1)" || len(snapshot.subrouteRows) != 1 || snapshot.subrouteRows[0][8] != "LINESTRING(121.5 25.0,121.6 25.1)" {
		t.Fatalf("published/persisted geometry = %v / %v, want first variant", sub, snapshot.subrouteRows)
	}
}

func TestSnapshotContractRejectsSecondJSONValueInCorrelatedFeed(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_shape|Taipei"] = []byte(`[] []`)
	if snapshot, err := readBusCitySnapshot(t.Context(), src, "Taipei"); err == nil || snapshot != nil {
		t.Fatalf("trailing JSON snapshot = %v, error = %v, want rejected correlated feed", snapshot, err)
	}
}

func TestSnapshotContractUnknownShapeDiagnosticsIdentifyNativeScope(t *testing.T) {
	for _, tc := range []struct{ name, subUID, scope string }{
		{name: "route geometry", subUID: "", scope: "routelevel"},
		{name: "subroute geometry", subUID: "TPE100", scope: "sub"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
			core, observed := observer.New(zap.WarnLevel)
			t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
			src := validBusSnapshotSource("Taipei")
			src.bodies["bus_shape|Taipei"] = []byte(fmt.Sprintf(`[{"RouteUID":"TPE1","SubRouteUID":%q,"Direction":1,"Geometry":"LINESTRING(121.5 25.0,121.6 25.1)"}]`, tc.subUID))
			snapshot := contractSnapshot(t, src, "Taipei")
			if len(snapshot.staticRows) != 1 {
				t.Fatalf("optional unknown geometry dropped route: %v", snapshot.staticRows)
			}
			logs := observed.FilterField(zap.String("reason", "shape_unknown_direction")).All()
			want := fmt.Sprintf("Shape[0]/%s->TPE100/1", tc.scope)
			if len(logs) != 1 || logs[0].ContextMap()["first"] != want {
				t.Fatalf("unknown shape diagnostic = %v, want first %q", logs, want)
			}
		})
	}
}
