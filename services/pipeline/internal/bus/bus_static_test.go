package bus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
)

type busSnapshotSource struct {
	bodies map[string][]byte
	times  map[string]time.Time
	cycles map[string]string
	errors map[string]error
	calls  []string
}

func (s *busSnapshotSource) DatasetJSON(_ context.Context, table, _, city string) ([]byte, time.Time, error) {
	key := table + "|" + city
	s.calls = append(s.calls, key)
	if err := s.errors[key]; err != nil {
		return nil, time.Time{}, err
	}
	return s.bodies[key], s.times[key], nil
}

func (s *busSnapshotSource) DatasetJSONWithLandingCycle(_ context.Context, table, _, city string) ([]byte, time.Time, string, error) {
	key := table + "|" + city
	s.calls = append(s.calls, key)
	if err := s.errors[key]; err != nil {
		return nil, time.Time{}, "", err
	}
	return s.bodies[key], s.times[key], s.cycles[key], nil
}

func validBusSnapshotSource(city string) *busSnapshotSource {
	now := time.Now()
	prefix := busmodel.CityPrefix[city]
	bodies := map[string][]byte{
		"bus_route|" + city:        []byte(`[{"RouteUID":"TPE1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":0,"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙","FirstBusTime":"06:00","LastBusTime":"23:00"}]}]`),
		"bus_stopofroute|" + city:  []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[{"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25.0}}]}]`),
		"bus_shape|" + city:        []byte(`[]`),
		"bus_schedule|" + city:     []byte(`[]`),
		"bus_station|" + city:      []byte(`[{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"甲站"},"stationposition":{"PositionLon":121.5,"PositionLat":25.0},"stationgroupid":"G1"}]`),
		"bus_stationgroup|" + city: []byte(`[]`),
		"bus_operator|" + city:     []byte(fmt.Sprintf(`[{"OperatorID":"OP1","OperatorName":{"Zh_tw":"測試客運"},"AuthorityCode":%q}]`, prefix)),
		"bus_routefare|" + city:    []byte(`[]`),
	}
	times := make(map[string]time.Time, len(bodies))
	cycles := make(map[string]string, len(bodies))
	for key := range bodies {
		times[key] = now
		cycles[key] = "cycle-current"
	}
	return &busSnapshotSource{bodies: bodies, times: times, cycles: cycles, errors: map[string]error{}}
}

func TestReadBusCitySnapshotAcceptsVerifiedEmptyOptionalDatasets(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("readBusCitySnapshot: %v", err)
	}
	if snapshot == nil || len(snapshot.subroutes) != 1 {
		t.Fatalf("snapshot = %#v, want one canonical subroute", snapshot)
	}
	if len(snapshot.scheduleRows) != 0 {
		t.Fatalf("schedule rows = %d, want verified empty", len(snapshot.scheduleRows))
	}
}

func TestReadBusCitySnapshotRejectsMissingOrStaleCorrelatedDataset(t *testing.T) {
	for _, tt := range []struct {
		name string
		when time.Time
	}{
		{name: "missing landing state", when: time.Time{}},
		{name: "stale landing state", when: time.Now().Add(-raw.StaleAfter - time.Hour)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			src := validBusSnapshotSource("Taipei")
			src.times["bus_shape|Taipei"] = tt.when
			_, err := readBusCitySnapshot(context.Background(), src, "Taipei")
			if !errors.Is(err, errBusSnapshotIncomplete) {
				t.Fatalf("error = %v, want errBusSnapshotIncomplete", err)
			}
		})
	}
}

func TestReadBusCitySnapshotRequiresOneDurableLandingCycleBeforeBegin(t *testing.T) {
	tests := []struct {
		name  string
		cycle string
	}{
		{name: "mixed cycle", cycle: "cycle-prior"},
		{name: "legacy state without cycle", cycle: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := validBusSnapshotSource("Taipei")
			src.cycles["bus_shape|Taipei"] = tt.cycle
			beginner := &recordingBusBeginner{tx: &recordingBusTx{}}
			snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
			if err == nil {
				err = writeBusCitySnapshot(context.Background(), beginner, snapshot)
			}
			if !errors.Is(err, errBusSnapshotIncomplete) {
				t.Fatalf("error = %v, want errBusSnapshotIncomplete", err)
			}
			if beginner.begins != 0 {
				t.Fatalf("target transaction began %d times for inconsistent cycle", beginner.begins)
			}
		})
	}
}

func TestReadBusCitySnapshotRejectsNullCorrelatedDataset(t *testing.T) {
	for _, table := range []string{
		"bus_route", "bus_stopofroute", "bus_shape", "bus_schedule",
		"bus_station", "bus_stationgroup", "bus_operator", "bus_routefare",
	} {
		t.Run(table, func(t *testing.T) {
			src := validBusSnapshotSource("Taipei")
			src.bodies[table+"|Taipei"] = []byte(`null`)
			if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); err == nil {
				t.Fatalf("%s null payload returned nil", table)
			}
		})
	}
}

func TestReadBusCitySnapshotReturnsEverySourceReadFailure(t *testing.T) {
	for _, table := range []string{
		"bus_route", "bus_stopofroute", "bus_shape", "bus_schedule",
		"bus_station", "bus_stationgroup", "bus_operator", "bus_routefare",
	} {
		t.Run(table, func(t *testing.T) {
			want := errors.New("read " + table)
			src := validBusSnapshotSource("Taipei")
			src.errors[table+"|Taipei"] = want
			if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); !errors.Is(err, want) {
				t.Fatalf("error = %v, want source error %v", err, want)
			}
		})
	}
}

func TestReadBusCitySnapshotRejectsForeignUIDsAndParentMismatchBeforeBegin(t *testing.T) {
	tests := []struct {
		name  string
		table string
		body  string
		city  string
	}{
		{
			name:  "route and subroute belong to another city",
			table: "bus_route",
			city:  "Taipei",
			body:  `[{"RouteUID":"NWT1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[{"SubRouteUID":"NWT100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":0}]}]`,
		},
		{
			name:  "stop of route declares the wrong parent",
			table: "bus_stopofroute",
			city:  "Taipei",
			body:  `[{"RouteUID":"TPE_OTHER","SubRouteUID":"TPE100","Direction":0,"Stops":[{"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}}]}]`,
		},
		{
			name:  "schedule declares the wrong parent",
			table: "bus_schedule",
			city:  "Taipei",
			body:  `[{"RouteUID":"TPE_OTHER","SubRouteUID":"TPE100","Direction":0,"Frequencys":[{"StartTime":"06:00","EndTime":"07:00","MinHeadwayMins":5,"MaxHeadwayMins":10}]}]`,
		},
		{
			name:  "station belongs to another city",
			table: "bus_station",
			city:  "Taipei",
			body:  `[{"stationuid":"NWTST1","stationid":"ST1","stationname":{"Zh_tw":"甲站"},"stationposition":{"PositionLon":121.5,"PositionLat":25}}]`,
		},
		{
			name:  "station group belongs to another city",
			table: "bus_stationgroup",
			city:  "Taipei",
			body:  `[{"stationgroupuid":"NWTG1","stationgroupid":"G1","stationgroupname":{"Zh_tw":"甲站"},"stationgroupposition":{"PositionLon":121.5,"PositionLat":25}}]`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := validBusSnapshotSource(tt.city)
			src.bodies[tt.table+"|"+tt.city] = []byte(tt.body)
			beginner := &recordingBusBeginner{tx: &recordingBusTx{}}
			snapshot, err := readBusCitySnapshot(context.Background(), src, tt.city)
			if err == nil {
				err = writeBusCitySnapshot(context.Background(), beginner, snapshot)
			}
			if !errors.Is(err, errBusSnapshotInvalid) {
				t.Fatalf("error = %v, want errBusSnapshotInvalid", err)
			}
			if beginner.begins != 0 {
				t.Fatalf("target transaction began %d times for invalid source", beginner.begins)
			}
		})
	}
}

func TestReadBusCitySnapshotRejectsCanonicalSubrouteParentCollisionBeforeBegin(t *testing.T) {
	const city = "InterCity"
	src := validBusSnapshotSource(city)
	src.bodies["bus_operator|"+city] = []byte(`[{"OperatorID":"OP1","OperatorName":{"Zh_tw":"測試客運"},"AuthorityCode":"THB"}]`)
	src.bodies["bus_route|"+city] = []byte(`[
		{"RouteUID":"THB_A","RouteName":{"Zh_tw":"A"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[{"SubRouteUID":"THB096801","SubRouteID":"096801","SubRouteName":{"Zh_tw":"A"},"Direction":0}]},
		{"RouteUID":"THB_B","RouteName":{"Zh_tw":"B"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[{"SubRouteUID":"THB096802","SubRouteID":"096802","SubRouteName":{"Zh_tw":"B"},"Direction":0}]}
	]`)
	beginner := &recordingBusBeginner{tx: &recordingBusTx{}}
	snapshot, err := readBusCitySnapshot(context.Background(), src, city)
	if err == nil {
		err = writeBusCitySnapshot(context.Background(), beginner, snapshot)
	}
	if !errors.Is(err, errBusSnapshotConflict) {
		t.Fatalf("error = %v, want errBusSnapshotConflict", err)
	}
	if beginner.begins != 0 {
		t.Fatalf("target transaction began %d times for canonical collision", beginner.begins)
	}
}

func TestReadBusCitySnapshotRejectsMalformedOrDivergentOperatorsBeforeBegin(t *testing.T) {
	tests := []struct {
		name string
		body string
		want error
	}{
		{name: "missing authority", body: `[{"OperatorID":"OP1","OperatorName":{"Zh_tw":"測試客運"}}]`, want: errBusSnapshotInvalid},
		{name: "wrong authority", body: `[{"OperatorID":"OP1","OperatorName":{"Zh_tw":"測試客運"},"AuthorityCode":"NWT"}]`, want: errBusSnapshotInvalid},
		{name: "missing name", body: `[{"OperatorID":"OP1","AuthorityCode":"TPE"}]`, want: errBusSnapshotInvalid},
		{name: "divergent duplicate", body: `[
			{"OperatorID":"OP1","OperatorName":{"Zh_tw":"甲"},"AuthorityCode":"TPE"},
			{"OperatorID":"OP1","OperatorName":{"Zh_tw":"乙"},"AuthorityCode":"TPE"}
		]`, want: errBusSnapshotConflict},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := validBusSnapshotSource("Taipei")
			src.bodies["bus_operator|Taipei"] = []byte(tt.body)
			beginner := &recordingBusBeginner{tx: &recordingBusTx{}}
			snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
			if err == nil {
				err = writeBusCitySnapshot(context.Background(), beginner, snapshot)
			}
			if !errors.Is(err, tt.want) {
				t.Fatalf("error = %v, want %v", err, tt.want)
			}
			if beginner.begins != 0 {
				t.Fatalf("target transaction began %d times for invalid operators", beginner.begins)
			}
		})
	}
}

func TestReadBusCitySnapshotUsesCanonicalInterCityDirectionForEndpoints(t *testing.T) {
	const city = "InterCity"
	src := validBusSnapshotSource(city)
	src.bodies["bus_operator|"+city] = []byte(`[{"OperatorID":"OP1","OperatorName":{"Zh_tw":"測試客運"},"AuthorityCode":"THB"}]`)
	src.bodies["bus_route|"+city] = []byte(`[{"RouteUID":"THB0968","RouteName":{"Zh_tw":"0968"},"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙","Operators":[{"OperatorID":"OP1"}],"SubRoutes":[
		{"SubRouteUID":"THB096801","SubRouteID":"096801","SubRouteName":{"Zh_tw":"0968"},"Direction":9},
		{"SubRouteUID":"THB096802","SubRouteID":"096802","SubRouteName":{"Zh_tw":"0968"},"Direction":9}
	]}]`)
	src.bodies["bus_stopofroute|"+city] = []byte(`[
		{"RouteUID":"THB0968","SubRouteUID":"THB096801","Direction":9,"Stops":[{"StopUID":"THB_S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}}]},
		{"RouteUID":"THB0968","SubRouteUID":"THB096802","Direction":9,"Stops":[{"StopUID":"THB_S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}}]}
	]`)
	src.bodies["bus_station|"+city] = []byte(`[{"stationuid":"THBST1","stationid":"ST1","stationname":{"Zh_tw":"甲"},"stationposition":{"PositionLon":121.5,"PositionLat":25}}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, city)
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	route := snapshot.subroutes["THB0968"]
	if route == nil {
		t.Fatal("canonical route THB0968 missing")
	}
	if got := route.Directions[0]; got == nil || got.DepartureStopName != "甲" || got.DestinationStopName != "乙" {
		t.Fatalf("direction 0 endpoints = %#v, want 甲 -> 乙", got)
	}
	if got := route.Directions[1]; got == nil || got.DepartureStopName != "乙" || got.DestinationStopName != "甲" {
		t.Fatalf("direction 1 endpoints = %#v, want 乙 -> 甲", got)
	}
}

func TestDecodeStrictJSONArrayRejectsMalformedTrailingData(t *testing.T) {
	var target []json.RawMessage
	if err := decodeStrictJSONArray([]byte(`[] x]`), &target); err == nil {
		t.Fatal("malformed trailing data returned nil")
	}
}

func TestReadBusCitySnapshotRejectsZeroValidRoutesAndMalformedElement(t *testing.T) {
	for _, body := range []string{
		`[]`,
		`null`,
		`[{"RouteUID":"","RouteName":{"Zh_tw":""},"SubRoutes":[]}]`,
		`[{"RouteUID":`,
	} {
		src := validBusSnapshotSource("Taipei")
		src.bodies["bus_route|Taipei"] = []byte(body)
		if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); err == nil {
			t.Fatalf("route body %q returned nil error", body)
		}
	}
}

func TestReadBusCitySnapshotPreservesIntentionalScheduleDuplicates(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_schedule|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Timetables":[{"TripID":"CIRCULAR","ServiceDay":{"Monday":1},"StopTimes":[
		{"StopSequence":1,"StopUID":"S1","StopName":{"Zh_tw":"甲"},"ArrivalTime":"08:00","DepartureTime":"08:01"},
		{"StopSequence":2,"StopUID":"S1","StopName":{"Zh_tw":"甲"},"ArrivalTime":"08:20","DepartureTime":"08:21"}
	]}]}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	if got := len(snapshot.scheduleRows); got != 2 {
		t.Fatalf("circular schedule rows = %d, want 2", got)
	}
}

func TestReadBusCitySnapshotBuildsDeterministicManualGroupCentroid(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_station|Taipei"] = []byte(`[
		{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"同名站"},"stationposition":{"PositionLon":121.4,"PositionLat":25.0}},
		{"stationuid":"TPEST2","stationid":"ST2","stationname":{"Zh_tw":"同名站"},"stationposition":{"PositionLon":121.6,"PositionLat":25.2}}
	]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	if len(snapshot.groupRows) != 1 || len(snapshot.memberRows) != 2 {
		t.Fatalf("groups/members = %d/%d, want 1/2", len(snapshot.groupRows), len(snapshot.memberRows))
	}
	if lon, lat := snapshot.groupRows[0][3].(float64), snapshot.groupRows[0][4].(float64); lon != 121.5 || lat != 25.1 {
		t.Fatalf("manual centroid = (%v,%v), want (121.5,25.1)", lon, lat)
	}
}

func TestReadBusCitySnapshotStripsCityBusNameSuffix(t *testing.T) {
	// Keelung's city-bus stations carry "(市區公車)" while InterCity names the
	// same pole without it; the group-member fold compares the two by equality.
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_station|Taipei"] = []byte(`[
		{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"地方法院(市區公車)"},"stationposition":{"PositionLon":121.74,"PositionLat":25.13}},
		{"stationuid":"TPEST2","stationid":"ST2","stationname":{"Zh_tw":"地方法院"},"stationposition":{"PositionLon":121.74,"PositionLat":25.13}}
	]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	if len(snapshot.groupRows) != 1 {
		t.Fatalf("group rows = %d, want 1 (both names fold to 地方法院)", len(snapshot.groupRows))
	}
	if got := snapshot.groupRows[0][2].(string); got != "地方法院" {
		t.Fatalf("group name = %q, want 地方法院", got)
	}
	for i, row := range snapshot.memberRows {
		if got := row[3].(string); got != "地方法院" {
			t.Fatalf("member[%d] name = %q, want 地方法院", i, got)
		}
	}
	for i, row := range snapshot.stationRows {
		if got := row[2].(string); got != "地方法院" {
			t.Fatalf("station[%d] name = %q, want 地方法院", i, got)
		}
	}
}

func TestReadBusCitySnapshotDeduplicatesIdenticalStopsAndTakesFirstOnDivergence(t *testing.T) {
	// One divergent variant out of two is 50% of this fixture; the ratio gate
	// is covered by TestLoadQuarantineRatioGate.
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	src := validBusSnapshotSource("Taipei")
	one := string(src.bodies["bus_stopofroute|Taipei"])
	src.bodies["bus_stopofroute|Taipei"] = []byte("[" + one[1:len(one)-1] + "," + one[1:len(one)-1] + "]")
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("identical duplicate: %v", err)
	}
	if got := len(snapshot.subroutes["TPE100"].Directions[0].Stops); got != 1 {
		t.Fatalf("deduplicated stops = %d, want 1", got)
	}

	// TDX publishes two stop lists for one subroute/direction and does not say
	// which is right. Failing the city over it froze InterCity at its last good
	// snapshot indefinitely, so the first variant wins and the load continues.
	src = validBusSnapshotSource("Taipei")
	src.bodies["bus_stopofroute|Taipei"] = []byte(`[
		{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[{"StopUID":"S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}}]},
		{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[{"StopUID":"S2","StopName":{"Zh_tw":"乙"},"StopSequence":1,"StationID":"ST2","StopPosition":{"PositionLon":121.6,"PositionLat":25}}]}
	]`)
	snapshot, err = readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("divergent duplicate: %v, want the city to load with the first variant", err)
	}
	stops := snapshot.subroutes["TPE100"].Directions[0].Stops
	if len(stops) != 1 || stops[0].StopUID != "S1" {
		t.Fatalf("stops = %+v, want only the first variant (S1)", stops)
	}
}

// A co-operated route ships one stop list per operator, and N1 keys each
// estimate on the StopID of the operator running it. The discarded list's UIDs
// have to survive as aliases or those estimates match nothing.
func TestReadBusCitySnapshotKeepsDiscardedOperatorStopUIDsAsAliases(t *testing.T) {
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_stopofroute|Taipei"] = []byte(`[
		{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[
			{"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}},
			{"StopUID":"TPE_S2","StopName":{"Zh_tw":"乙"},"StopSequence":2,"StationID":"ST1","StopPosition":{"PositionLon":121.6,"PositionLat":25}}]},
		{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[
			{"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}},
			{"StopUID":"TPE_OP2_S2","StopName":{"Zh_tw":"乙"},"StopSequence":2,"StationID":"ST1","StopPosition":{"PositionLon":121.6,"PositionLat":25}},
			{"StopUID":"TPE_OP2_S3","StopName":{"Zh_tw":"丙"},"StopSequence":3,"StationID":"ST1","StopPosition":{"PositionLon":121.7,"PositionLat":25}}]}
	]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("readBusCitySnapshot: %v", err)
	}
	// Sequence 1 is identical in both lists (no alias needed) and sequence 3 has
	// no counterpart in the kept list (nothing to point at), so exactly one row.
	if len(snapshot.aliasRows) != 1 {
		t.Fatalf("alias rows = %#v, want only the sequence-2 pair", snapshot.aliasRows)
	}
	want := []any{"TPE100", int16(0), "TPE_OP2_S2", "TPE_S2"}
	for i, got := range snapshot.aliasRows[0] {
		if got != want[i] {
			t.Fatalf("alias row = %#v, want %#v", snapshot.aliasRows[0], want)
		}
	}
}

// TDX publishes (0,0) for stops and stations whose survey has not finished
// (Keelung is the documented case). It is source state, not a broken record, so
// the city still loads and keeps the stop.
func TestReadBusCitySnapshotKeepsUnsurveyedPositions(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_stopofroute|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[{"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":0,"PositionLat":0}}]}]`)
	src.bodies["bus_station|Taipei"] = []byte(`[{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"甲站"},"stationposition":{"PositionLon":0,"PositionLat":0},"stationgroupid":"G1"}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("unsurveyed position failed the city: %v", err)
	}
	stops := snapshot.subroutes["TPE100"].Directions[0].Stops
	if len(stops) != 1 || stops[0].StopUID != "TPE_S1" {
		t.Fatalf("stops = %+v, want the unsurveyed stop kept", stops)
	}
	if len(snapshot.stationRows) != 1 {
		t.Fatalf("station rows = %d, want the unsurveyed station kept", len(snapshot.stationRows))
	}

	// Identity is still fatal: a stop with no name is a broken record, not a
	// pending survey.
	src = validBusSnapshotSource("Taipei")
	src.bodies["bus_stopofroute|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[{"StopUID":"TPE_S1","StopName":{"Zh_tw":""},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.7,"PositionLat":25.1}}]}]`)
	if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); err == nil {
		t.Fatal("a nameless stop loaded, want the city rejected")
	}
}

func TestReadBusCitySnapshotMapsNativeFareAndMergesCanonicalOffers(t *testing.T) {
	const city = "InterCity"
	src := validBusSnapshotSource(city)
	src.bodies["bus_route|"+city] = []byte(`[{"RouteUID":"THB0968","RouteName":{"Zh_tw":"0968"},"SubRoutes":[{"SubRouteUID":"THB096801","SubRouteID":"096801","SubRouteName":{"Zh_tw":"0968"},"Direction":0}]}]`)
	src.bodies["bus_stopofroute|"+city] = []byte(`[{"RouteUID":"THB0968","SubRouteUID":"THB096801","Direction":0,"Stops":[{"StopUID":"S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}}]}]`)
	src.bodies["bus_station|"+city] = []byte(`[{"stationuid":"THBST1","stationid":"ST1","stationname":{"Zh_tw":"甲"},"stationposition":{"PositionLon":121.5,"PositionLat":25}}]`)
	src.bodies["bus_routefare|"+city] = []byte(`[{"RouteID":"0968","SubRouteID":"096801","FarePricingType":1,"IsFreeBus":0}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, city)
	if err != nil {
		t.Fatalf("native fare: %v", err)
	}
	if snapshot.subroutes["THB0968"].Fare == nil {
		t.Fatal("canonical subroute did not receive native SubRouteID fare")
	}

	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	src.bodies["bus_routefare|"+city] = []byte(`[
		{"RouteID":"0968","SubRouteID":"096801","FarePricingType":1,"IsForAllSubRoutes":1},
		{"RouteID":"0968","SubRouteID":"096802","FarePricingType":2,"IsForAllSubRoutes":1}
	]`)
	snapshot, err = readBusCitySnapshot(context.Background(), src, city)
	if err != nil {
		t.Fatalf("merged fare: %v, want the city to load with the first offer's scalars", err)
	}
	if got := snapshot.subroutes["THB0968"].Fare; got.GetFarePricingType() != 1 {
		t.Fatalf("fare = %+v, want the first offer (FarePricingType 1)", got)
	}
}

func TestReadBusCitySnapshotDropsUnorderedStopListAndItsDirection(t *testing.T) {
	// One unordered variant out of one is 100% of this fixture; the ratio gate is
	// covered by TestLoadQuarantineRatioGate.
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_route|Taipei"] = []byte(`[{"RouteUID":"TPE1","RouteName":{"Zh_tw":"1"},"SubRoutes":[
		{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"100"},"Direction":0,"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙"},
		{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"100"},"Direction":1,"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙"}
	]}]`)
	src.bodies["bus_station|Taipei"] = []byte(`[
		{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"甲"},"stationposition":{"PositionLon":121.5,"PositionLat":25.0}},
		{"stationuid":"TPEST2","stationid":"ST2","stationname":{"Zh_tw":"乙"},"stationposition":{"PositionLon":121.6,"PositionLat":25.0}}
	]`)
	// Direction 0's sequence restarts mid-list; direction 1 is clean.
	src.bodies["bus_stopofroute|Taipei"] = []byte(`[
		{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[
			{"StopUID":"S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}},
			{"StopUID":"S2","StopName":{"Zh_tw":"乙"},"StopSequence":1,"StationID":"ST2","StopPosition":{"PositionLon":121.6,"PositionLat":25}}
		]},
		{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":1,"Stops":[
			{"StopUID":"S2","StopName":{"Zh_tw":"乙"},"StopSequence":1,"StationID":"ST2","StopPosition":{"PositionLon":121.6,"PositionLat":25}}
		]}
	]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("unordered stop list: %v, want the city to load without that direction", err)
	}
	sub := snapshot.subroutes["TPE100"]
	if sub == nil {
		t.Fatal("subroute dropped, want it kept on its clean direction")
	}
	if _, ok := sub.Directions[0]; ok {
		t.Fatalf("directions = %v, want the unordered direction 0 pruned", sub.Directions)
	}
	// The pruned direction must not leave its endpoints on the subroute: direction
	// 1 is stored reversed, so inheriting from it flips departure/destination.
	if sub.DepartureStopName != "乙" || sub.DestinationStopName != "甲" {
		t.Fatalf("endpoints = %q -> %q, want the surviving direction's 乙 -> 甲", sub.DepartureStopName, sub.DestinationStopName)
	}

	// Every direction unordered: the subroute goes, and with it the last one, so
	// the city fails instead of writing an empty snapshot.
	src.bodies["bus_stopofroute|Taipei"] = []byte(`[
		{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Stops":[
			{"StopUID":"S1","StopName":{"Zh_tw":"甲"},"StopSequence":1,"StationID":"ST1","StopPosition":{"PositionLon":121.5,"PositionLat":25}},
			{"StopUID":"S2","StopName":{"Zh_tw":"乙"},"StopSequence":1,"StationID":"ST2","StopPosition":{"PositionLon":121.6,"PositionLat":25}}
		]}
	]`)
	if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); !errors.Is(err, errBusSnapshotInvalid) {
		t.Fatalf("every subroute pruned: err = %v, want errBusSnapshotInvalid", err)
	}
}

func TestBusScheduleRowsUseDepartureTime(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_schedule|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Timetables":[{"TripID":"TRIP","ServiceDay":{"Monday":1},"StopTimes":[{"StopSequence":1,"StopUID":"S1","StopName":{"Zh_tw":"甲"},"ArrivalTime":"08:00","DepartureTime":"08:03"}]}]}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	if got := snapshot.scheduleRows[0][9]; got != "08:03" {
		t.Fatalf("departure column = %v, want 08:03", got)
	}
}

func TestBusSchedulePayloadCarriesOnlyTripOrigin(t *testing.T) {
	src := validBusSnapshotSource("Taipei")
	// Stop times arrive out of sequence order: the payload row must still be the
	// origin (sequence 1), not the first element.
	src.bodies["bus_schedule|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Timetables":[{"TripID":"TRIP","ServiceDay":{"Monday":1},"StopTimes":[{"StopSequence":3,"StopUID":"S3","StopName":{"Zh_tw":"丙"},"ArrivalTime":"08:20","DepartureTime":"08:21"},{"StopSequence":1,"StopUID":"S1","StopName":{"Zh_tw":"甲"},"ArrivalTime":"08:00","DepartureTime":"08:03"}]}]}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	if got := len(snapshot.scheduleRows); got != 2 {
		t.Fatalf("db rows = %d, want 2 (every stop is still stored)", got)
	}
	schedules := snapshot.subroutes["TPE100"].Directions[0].Schedules
	if len(schedules) != 1 {
		t.Fatalf("payload schedules = %d, want 1 per trip", len(schedules))
	}
	if got := schedules[0].MaxHeadwayMinsDepartureTime; got != "08:03" {
		t.Fatalf("origin departure = %q, want 08:03", got)
	}
	if got := schedules[0].ServiceDay; got != 1 {
		t.Fatalf("service day mask = %d, want 1 (Monday)", got)
	}
}

func TestNormalizeClock(t *testing.T) {
	cases := []struct {
		in   string
		want string
		ok   bool
	}{
		{"05:10", "05:10", true},
		{"0510", "05:10", true},   // the bare shape Taipei publishes
		{"0700", "07:00", true},   // NewTaipei FirstBusTime
		{"25:30", "25:30", true},  // service day runs past midnight
		{"29:59", "29:59", true},  // upper bound
		{" 0510 ", "05:10", true}, // TDX pads some fields
		{"30:00", "", false},      // hour out of range
		{"05:60", "", false},      // minute out of range
		{"5:10", "", false},
		{"051", "", false},
		{"05:1o", "", false},
		{"abcd", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, ok := normalizeClock(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("normalizeClock(%q) = (%q,%v), want (%q,%v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestReadBusCitySnapshotQuarantinesRecordDefects(t *testing.T) {
	// These fixtures are one record wide, so any drop is 100% of its kind. The
	// ratio gate is exercised in TestLoadQuarantineRatioGate; here it is the
	// per-record drop path under test.
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	tests := []struct {
		name  string
		table string
		body  string
	}{
		{
			// Taoyuan: Shape[107] references unknown TAO3021/1.
			name:  "shape referencing an unknown subroute",
			table: "bus_shape",
			body:  `[{"RouteUID":"TPE1","SubRouteUID":"TPE999","Direction":1,"Geometry":"LINESTRING(121.5 25.0,121.6 25.1)"}]`,
		},
		{
			// Kinmen: Schedule[0]: timetable has empty TripID.
			name:  "schedule with a malformed timetable",
			table: "bus_schedule",
			body:  `[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Timetables":[{"TripID":"","StopTimes":[{"StopUID":"TPE_S1","StopName":{"Zh_tw":"甲站"},"StopSequence":1,"ArrivalTime":"06:00","DepartureTime":"06:00"}]}]}]`,
		},
		{
			// Changhua/Nantou/Yilan: divergent Schedule variants.
			name:  "divergent schedule variants",
			table: "bus_schedule",
			body: `[{"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Frequencys":[{"StartTime":"06:00","EndTime":"07:00","MinHeadwayMins":5,"MaxHeadwayMins":10}]},
			        {"RouteUID":"TPE1","SubRouteUID":"TPE100","Direction":0,"Frequencys":[{"StartTime":"06:00","EndTime":"08:00","MinHeadwayMins":9,"MaxHeadwayMins":20}]}]`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := validBusSnapshotSource("Taipei")
			src.bodies[tt.table+"|Taipei"] = []byte(tt.body)
			snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
			if err != nil {
				t.Fatalf("error = %v, want the city to load with the record dropped", err)
			}
			if snapshot.subroutes["TPE100"] == nil {
				t.Fatal("TPE100 missing: the good subroute must survive the drop")
			}
		})
	}
}

// Tainan: Route[15].SubRoutes[0] has invalid identity/direction. The bad
// subroute goes, its siblings load.
func TestReadBusCitySnapshotDropsUnusableSubrouteKeepsSiblings(t *testing.T) {
	// One of two subroutes drops, which is 50% of a two-record fixture; the
	// ratio gate is covered by TestLoadQuarantineRatioGate.
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_route|Taipei"] = []byte(`[{"RouteUID":"TPE1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[
		{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":0,"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙"},
		{"SubRouteUID":"TPE101","SubRouteID":"101","SubRouteName":{"Zh_tw":""},"Direction":0}
	]}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("error = %v, want the city to load with the bad subroute dropped", err)
	}
	if snapshot.subroutes["TPE100"] == nil {
		t.Fatal("TPE100 missing: the valid sibling must survive")
	}
	if snapshot.subroutes["TPE101"] != nil {
		t.Fatal("TPE101 present: a subroute with no usable identity must be dropped")
	}
}

// Taipei: TPE101320/0 HolidayFirstBusTime="0510". A time that survives neither
// shape blanks that one field; empty already means "not published" to every
// reader, so the route stays usable rather than vanishing.
func TestReadBusCitySnapshotBlanksUnparseableClockKeepsSubroute(t *testing.T) {
	// A blanked clock counts as a drop against a one-subroute fixture; the
	// ratio gate is covered by TestLoadQuarantineRatioGate.
	t.Setenv("LOAD_QUARANTINE_MAX_RATIO", "1")
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_route|Taipei"] = []byte(`[{"RouteUID":"TPE1","RouteName":{"Zh_tw":"1路"},"Operators":[{"OperatorID":"OP1"}],"SubRoutes":[
		{"SubRouteUID":"TPE100","SubRouteID":"100","SubRouteName":{"Zh_tw":"1路"},"Direction":0,"DepartureStopNameZh":"甲","DestinationStopNameZh":"乙","FirstBusTime":"0600","LastBusTime":"garbage"}
	]}]`)
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatalf("error = %v, want the city to load", err)
	}
	dir := snapshot.subroutes["TPE100"].Directions[0]
	if dir.FirstBusTime != "06:00" {
		t.Fatalf("FirstBusTime = %q, want the bare HHMM shape normalized to 06:00", dir.FirstBusTime)
	}
	if dir.LastBusTime != "" {
		t.Fatalf("LastBusTime = %q, want an unparseable time blanked", dir.LastBusTime)
	}
}
