package dataset

import (
	"reflect"
	"slices"
	"testing"
	"time"
)

func TestDatasetLandingURLs(t *testing.T) {
	cases := []struct {
		family              LandFamily
		segment, part, want string
	}{
		{FamilyBusCity, "Route", "Taipei", "/v2/Bus/Route/City/Taipei"},
		{FamilyBusCity, "Route", "InterCity", "/v2/Bus/Route/InterCity"},
		{FamilyBikeCity, "Station", "Kaohsiung", "/v2/Bike/Station/City/Kaohsiung"},
		{FamilyMetroSystem, "Station", "TRTC", "/v2/Rail/Metro/Station/TRTC"},
		{FamilyRailSingle, "TRA/Station", "ignored", "/v2/Rail/TRA/Station"},
		{FamilyRailDate, "THSR/DailyTimetable", "2026-10-10", "/v2/Rail/THSR/DailyTimetable/TrainDate/2026-10-10"},
		{FamilyNone, "", "", ""},
		{LandFamily(99), "Route", "Taipei", ""},
	}
	for _, tc := range cases {
		if got := (Spec{Family: tc.family, APISeg: tc.segment}).URL(tc.part); got != tc.want {
			t.Errorf("family=%v part=%q: %q != %q", tc.family, tc.part, got, tc.want)
		}
	}
}

func TestRegistryIdentitiesAndPartitions(t *testing.T) {
	seen := make(map[string]bool)
	for _, spec := range Registry() {
		if spec.RawTable == "" || seen[spec.RawTable] {
			t.Fatalf("empty or duplicate table %q", spec.RawTable)
		}
		seen[spec.RawTable] = true
		if spec.Fetched() != (spec.Family != FamilyNone && !spec.LandOnly) {
			t.Fatalf("wrong fetched classification: %s", spec.RawTable)
		}
		if spec.Partitions == nil {
			continue
		}
		parts := spec.Partitions()
		if len(parts) == 0 {
			t.Fatalf("empty partition set: %s", spec.RawTable)
		}
		if spec.Name != nil {
			names := map[string]bool{}
			for _, part := range parts {
				name := spec.Name(part)
				if name == "" || names[name] {
					t.Fatalf("empty/duplicate conditional identity: %s/%q", spec.RawTable, part)
				}
				names[name] = true
			}
		}
		loads := spec.LoadPartitions()
		if len(loads) == 0 {
			t.Fatalf("empty load partitions: %s", spec.RawTable)
		}
		if spec.Family != FamilyNone {
			target, ok := RawTargetIndex[FamSeg{spec.Family, spec.APISeg}]
			if !ok || target.RawTable != spec.RawTable {
				t.Fatalf("reverse target mismatch: %s", spec.RawTable)
			}
		}
	}
	if (Spec{}).Fetched() || (Spec{Family: FamilyRailSingle, LandOnly: true}).Fetched() {
		t.Fatal("disabled sources were fetched")
	}
}

func TestCityPartitionContracts(t *testing.T) {
	loads := BusLoadCities()
	if slices.Contains(loads, "LienchiangCounty") || loads[len(loads)-1] != "InterCity" {
		t.Fatalf("bus load cities = %v", loads)
	}
	if !reflect.DeepEqual(DisplayStopCities(), []string{"Taipei", "NewTaipei", "Taoyuan", "Taichung", "Tainan"}) {
		t.Fatal("display-stop city contract changed")
	}
	for _, city := range BikeCities() {
		if BikeSkip[city] {
			t.Fatalf("bike skipped city was landed: %s", city)
		}
	}
	for _, city := range []string{"Taipei", "NewTaipei", "Tainan", "KinmenCounty", "LienchiangCounty"} {
		if !BusDailyTimetableSkip(city) || slices.Contains(DailyTimetableCities(), city) {
			t.Fatalf("unavailable daily feed included: %s", city)
		}
	}
	if BusDailyTimetableSkip("Kaohsiung") || !slices.Contains(DailyTimetableCities(), "Kaohsiung") {
		t.Fatal("available daily feed excluded")
	}
	dailyLoads := DailyTimetableLoadCities()
	if dailyLoads[len(dailyLoads)-1] != DataTaipeiCity {
		t.Fatal("Data.taipei partition absent")
	}
	if len(AllCities()) <= len(loads) {
		t.Fatal("load exclusions vanished")
	}
}

func TestRailWindowIncludesBothEndpoints(t *testing.T) {
	before := time.Now().Format(time.DateOnly)
	dates := RailDateWindow(2)
	after := time.Now().Format(time.DateOnly)
	if len(dates) != 3 || (dates[0] != before && dates[0] != after) {
		t.Fatalf("window = %v", dates)
	}
	start, err := time.Parse(time.DateOnly, dates[0])
	if err != nil {
		t.Fatal(err)
	}
	for i, date := range dates {
		if date != start.AddDate(0, 0, i).Format(time.DateOnly) {
			t.Fatalf("date %d = %s", i, date)
		}
	}
	if len(RailDateWindow(-1)) != 0 {
		t.Fatal("empty past window changed")
	}
}
