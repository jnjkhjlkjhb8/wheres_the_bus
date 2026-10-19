package bus

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

type loadOnlyBusSource struct{ pipeline.LoadSource }

func TestSnapshotRequiresSupportedSourceAndCity(t *testing.T) {
	for _, input := range []struct {
		source pipeline.LoadSource
		city   string
		want   error
	}{
		{nil, "Taipei", errBusSnapshotIncomplete},
		{validBusSnapshotSource("Taipei"), "missing", errBusSnapshotInvalid},
		{loadOnlyBusSource{validBusSnapshotSource("Taipei")}, "Taipei", errBusSnapshotIncomplete},
	} {
		if _, err := readBusCitySnapshot(context.Background(), input.source, input.city); !errors.Is(err, input.want) {
			t.Fatalf("source/city validation: %v", err)
		}
	}
}

func TestSnapshotAppliesRouteAndSubrouteShapes(t *testing.T) {
	for _, subroute := range []string{"", "TPE100"} {
		src := validBusSnapshotSource("Taipei")
		src.bodies["bus_shape|Taipei"] = []byte(`[{"RouteUID":"TPE1","SubRouteUID":"` + subroute + `","Direction":0,"Geometry":"LINESTRING(121.5 25,121.6 25.1)"}]`)
		snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
		if err != nil {
			t.Fatal(err)
		}
		if geometry := snapshot.subroutes["TPE100"].Directions[0].Geometry; geometry != "LINESTRING(121.5 25,121.6 25.1)" {
			t.Fatalf("geometry = %s", geometry)
		}
	}
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_shape|Taipei"] = []byte(`[{"RouteUID":"TPEOTHER","SubRouteUID":"TPE100","Direction":0,"Geometry":"LINESTRING(121.5 25,121.6 25.1)"}]`)
	if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); !errors.Is(err, errBusSnapshotInvalid) {
		t.Fatalf("parent mismatch = %v", err)
	}
}

func TestSnapshotHandlesStationDuplicatesAndLocalReferences(t *testing.T) {
	for _, station := range []string{
		`{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"甲站"},"stationposition":{"PositionLon":121.5,"PositionLat":25.0},"stationgroupid":"G1"}`,
		`{"stationuid":"TPEALIAS","stationid":"ST1","stationname":{"Zh_tw":"甲站"},"stationposition":{"PositionLon":121.5,"PositionLat":25.0},"stationgroupid":"G1"}`,
	} {
		src := validBusSnapshotSource("Taipei")
		src.bodies["bus_station|Taipei"] = []byte("[" + station + "," + station + "]")
		snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
		if err != nil {
			t.Fatal(err)
		}
		if len(snapshot.stationRows) != 1 {
			t.Fatalf("duplicates created %d station rows", len(snapshot.stationRows))
		}
	}
	for _, stations := range []string{
		`[]`,
		`[{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"甲站"}},{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"乙站"}}]`,
		`[{"stationuid":"TPEST1","stationid":"ST1","stationname":{"Zh_tw":"甲站"}},{"stationuid":"TPEST2","stationid":"ST1","stationname":{"Zh_tw":"甲站"}}]`,
	} {
		src := validBusSnapshotSource("Taipei")
		src.bodies["bus_station|Taipei"] = []byte(stations)
		if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); err == nil {
			t.Fatal("missing/conflicting station accepted")
		}
	}
}

func TestSnapshotUsesStationGroupsAndRejectsDivergentIdentifiers(t *testing.T) {
	group := `{"StationGroupUID":"TPEG1","StationGroupID":"G1","StationGroupName":{"Zh_tw":"甲站"},"StationGroupPosition":{"PositionLon":121.5,"PositionLat":25}}`
	src := validBusSnapshotSource("Taipei")
	src.bodies["bus_stationgroup|Taipei"] = []byte("[" + group + "," + group + "]")
	snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.groupRows) != 1 || snapshot.memberRows[0][1] != "TPEG1" || snapshot.groupRows[0][5] != "tdx" {
		t.Fatalf("group rows/members = %v / %v", snapshot.groupRows, snapshot.memberRows)
	}
	for _, variant := range []map[string]any{
		{"StationGroupUID": "TPEG2"}, {"StationGroupID": "G2"}, {"StationGroupName": map[string]string{"Zh_tw": "乙站"}},
	} {
		var decoded map[string]any
		if err := json.Unmarshal([]byte(group), &decoded); err != nil {
			t.Fatal(err)
		}
		for key, value := range variant {
			decoded[key] = value
		}
		body, err := json.Marshal(decoded)
		if err != nil {
			t.Fatal(err)
		}
		src := validBusSnapshotSource("Taipei")
		src.bodies["bus_stationgroup|Taipei"] = []byte("[" + group + "," + string(body) + "]")
		if _, err := readBusCitySnapshot(context.Background(), src, "Taipei"); !errors.Is(err, errBusSnapshotConflict) {
			t.Fatalf("divergent group accepted: %v", err)
		}
	}
}

func TestSnapshotMergesIdenticalDirectionsAndRejectsConflictingClocks(t *testing.T) {
	for _, clock := range []string{"06:00", "07:00"} {
		src := validBusSnapshotSource("Taipei")
		var routes []busmodel.RawRoute
		if err := json.Unmarshal(src.bodies["bus_route|Taipei"], &routes); err != nil {
			t.Fatal(err)
		}
		duplicate := routes[0].SubRoutes[0]
		duplicate.FirstBusTime = clock
		routes[0].SubRoutes = append(routes[0].SubRoutes, duplicate)
		body, err := json.Marshal(routes)
		if err != nil {
			t.Fatal(err)
		}
		src.bodies["bus_route|Taipei"] = body
		snapshot, err := readBusCitySnapshot(context.Background(), src, "Taipei")
		if clock == "07:00" {
			if !errors.Is(err, errBusSnapshotConflict) {
				t.Fatalf("conflicting clock = %v", err)
			}
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if len(snapshot.subroutes) != 1 || len(snapshot.subroutes["TPE100"].Directions) != 1 {
			t.Fatalf("duplicated directions = %+v", snapshot.subroutes)
		}
	}
}
