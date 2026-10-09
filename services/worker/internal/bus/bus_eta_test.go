package bus

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
)

func TestBusEtaCityListsPartitionCities(t *testing.T) {
	seen := make(map[string]int, len(busmodel.Cities))
	for _, city := range _busEtaFastCities {
		seen[city]++
	}
	for _, city := range _busEtaSlowCities {
		seen[city]++
	}
	if len(seen) != len(busmodel.Cities) {
		t.Fatalf("fast+slow cover %d distinct cities, want %d", len(seen), len(busmodel.Cities))
	}
	for _, city := range busmodel.Cities {
		if seen[city] != 1 {
			t.Errorf("city %q appears %d times across fast+slow, want exactly 1", city, seen[city])
		}
	}
	for city := range _dataTaipeiDynamicCities {
		if !slices.Contains(_busEtaFastCities, city) {
			t.Errorf("dataTaipeiDynamicCities city %q missing from busEtaFastCities", city)
		}
	}
}

func TestDecodeBusEtaArray(t *testing.T) {
	tests := []struct {
		name         string
		body         string
		wantLen      int
		wantComplete bool
	}{
		{name: "full array", body: `[{"StopUID":"A","EstimateTime":60},{"StopUID":"B","EstimateTime":120}]`, wantLen: 2, wantComplete: true},
		{name: "empty array is complete", body: `[]`, wantLen: 0, wantComplete: true},
		{name: "truncated mid-element", body: `[{"StopUID":"A","EstimateTime":60},{"StopUID":"B",`, wantLen: 1, wantComplete: false},
		{name: "missing closing bracket", body: `[{"StopUID":"A","EstimateTime":60}`, wantLen: 1, wantComplete: false},
		{name: "not an array", body: `garbage`, wantLen: 0, wantComplete: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dec := json.NewDecoder(strings.NewReader(tt.body))
			eat, err := decodeBusEtaArray(dec)
			if (err == nil) != tt.wantComplete {
				t.Fatalf("err = %v, want complete = %v", err, tt.wantComplete)
			}
			if len(eat) != tt.wantLen {
				t.Fatalf("len(eat) = %d, want %d", len(eat), tt.wantLen)
			}
		})
	}
}

func TestDecodeBusEtaArrayFieldNames(t *testing.T) {
	t.Run("Keelung names the subroute", func(t *testing.T) {
		body := `[{"PlateNumb":"FAC-156","StopUID":"KEE306194","RouteUID":"KEE0211","SubRouteUID":"KEE021101","Direction":0,"EstimateTime":1118,"StopStatus":0,"UpdateTime":"2026-07-12T20:20:34+08:00"}]`
		eat, err := decodeBusEtaArray(json.NewDecoder(strings.NewReader(body)))
		if err != nil || len(eat) != 1 {
			t.Fatalf("err=%v len=%d, want nil/1", err, len(eat))
		}
		if eat[0].EstimatedTime != 1118 {
			t.Errorf("EstimatedTime = %d, want 1118 — the TDX field is EstimateTime", eat[0].EstimatedTime)
		}
		if eat[0].SubRouteUID != "KEE021101" || eat[0].RouteUID != "KEE0211" {
			t.Errorf("uids = %q/%q, want KEE021101/KEE0211", eat[0].SubRouteUID, eat[0].RouteUID)
		}
	})

	t.Run("Taipei identifies the arrival by route only", func(t *testing.T) {
		body := `[{"StopUID":"TPE36407","RouteUID":"TPE10442","RouteID":"10442","Direction":1,"EstimateTime":864,"StopStatus":0,"SrcUpdateTime":"2026-07-12T20:20:30+08:00"}]`
		eat, err := decodeBusEtaArray(json.NewDecoder(strings.NewReader(body)))
		if err != nil || len(eat) != 1 {
			t.Fatalf("err=%v len=%d, want nil/1", err, len(eat))
		}
		if eat[0].EstimatedTime != 864 {
			t.Errorf("EstimatedTime = %d, want 864 — the TDX field is EstimateTime", eat[0].EstimatedTime)
		}
		if eat[0].SubRouteUID != "" {
			t.Errorf("SubRouteUID = %q, want empty: Taipei omits it, which is what buildBusEtaMap's route fan-out exists for", eat[0].SubRouteUID)
		}
		if eat[0].RouteUID != "TPE10442" {
			t.Errorf("RouteUID = %q, want TPE10442", eat[0].RouteUID)
		}
	})
}

func TestServedCityPrefixesResolve(t *testing.T) {
	for _, c := range busmodel.Cities {
		if busmodel.CityPrefix[c] == "" {
			t.Errorf("city %q from cities has no citymap prefix: bus ETA would be skipped for it, and its LIKE '%%' partition delete would wipe every other city's stop-map and schedule rows", c)
		}
	}
}

// citymap and citymap2 must stay a strict inverse pair: citymap2 resolves a
// prefix back to a TDX city code, so its values have to be keys of citymap.
func TestCityMapsAreInverse(t *testing.T) {
	for city, prefix := range busmodel.CityPrefix {
		if got := busmodel.CityToCode[prefix]; got != city {
			t.Errorf("citymap2[%q] = %q, want %q", prefix, got, city)
		}
	}
	if len(busmodel.CityPrefix) != len(busmodel.CityToCode) {
		t.Errorf("citymap has %d entries, citymap2 has %d", len(busmodel.CityPrefix), len(busmodel.CityToCode))
	}
}

func TestPickBusEstimate(t *testing.T) {
	tests := []struct {
		name string
		prev busmodel.RawEstimated
		next busmodel.RawEstimated
		want busmodel.RawEstimated
	}{
		{
			name: "status 0 beats status 1",
			prev: busmodel.RawEstimated{StopStatus: 1, EstimatedTime: 10},
			next: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 300},
			want: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 300},
		},
		{
			name: "existing status 0 kept over incoming status 1",
			prev: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 120},
			next: busmodel.RawEstimated{StopStatus: 1, EstimatedTime: 5},
			want: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 120},
		},
		{
			name: "smaller estimate wins among status 0",
			prev: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 300},
			next: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 60},
			want: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 60},
		},
		{
			name: "larger estimate rejected among status 0",
			prev: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 60},
			next: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 300},
			want: busmodel.RawEstimated{StopStatus: 0, EstimatedTime: 60},
		},
		{
			name: "first seen kept when all non-zero",
			prev: busmodel.RawEstimated{StopStatus: 1, EstimatedTime: 200},
			next: busmodel.RawEstimated{StopStatus: 1, EstimatedTime: 5},
			want: busmodel.RawEstimated{StopStatus: 1, EstimatedTime: 200},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := pickBusEstimate(tt.prev, tt.next)
			if got != tt.want {
				t.Fatalf("pickBusEstimate() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestBusArrivalDispatchRequiresUsableETA(t *testing.T) {
	for _, tc := range []struct {
		name   string
		found  bool
		status uint8
		eta    int32
		want   bool
	}{
		{name: "missing", found: false, status: 0, eta: 60, want: false},
		{name: "unavailable status", found: true, status: 1, eta: 60, want: false},
		{name: "zero", found: true, status: 0, eta: 0, want: false},
		{name: "negative", found: true, status: 0, eta: -1, want: false},
		{name: "usable", found: true, status: 0, eta: 60, want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldDispatchBusArrival(tc.found, tc.status, tc.eta); got != tc.want {
				t.Fatalf("got=%v want=%v", got, tc.want)
			}
		})
	}
}
