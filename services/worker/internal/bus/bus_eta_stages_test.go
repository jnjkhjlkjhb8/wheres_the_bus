package bus

import (
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

func TestAdjustedEstimate(t *testing.T) {
	now := time.Date(2026, 7, 10, 8, 0, 30, 0, time.UTC)
	tests := []struct {
		name string
		eta  busmodel.RawEstimated
		want int32
	}{
		{
			name: "unparseable src time keeps raw estimate",
			eta:  busmodel.RawEstimated{EstimatedTime: 120, SrcUpdateTime: ""},
			want: 120,
		},
		{
			name: "stale src time ages estimate forward",
			eta:  busmodel.RawEstimated{EstimatedTime: 120, SrcUpdateTime: "2026-07-10T08:00:00Z"},
			want: 90, // 120 - 30s of snapshot age
		},
		{
			name: "fresh src time equal to now leaves estimate",
			eta:  busmodel.RawEstimated{EstimatedTime: 60, SrcUpdateTime: "2026-07-10T08:00:30Z"},
			want: 60,
		},
		{
			name: "snapshot older than its estimate clamps to zero",
			eta:  busmodel.RawEstimated{EstimatedTime: 10, SrcUpdateTime: "2026-07-10T08:00:00Z"},
			want: 0,
		},
		{
			name: "negative estimate from tdx clamps to zero",
			eta:  busmodel.RawEstimated{EstimatedTime: -5, SrcUpdateTime: ""},
			want: 0,
		},
		{
			name: "zoneless src time reads as taipei local",
			eta:  busmodel.RawEstimated{EstimatedTime: 120, SrcUpdateTime: "2026-07-10T16:00:00"},
			want: 90, // 16:00 +08:00 == 08:00Z, 30s before now
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := adjustedEstimate(tt.eta, now); got != tt.want {
				t.Fatalf("adjustedEstimate() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestArrivingExpired(t *testing.T) {
	now := time.Date(2026, 7, 10, 8, 0, 0, 0, time.UTC)
	tests := []struct {
		name string
		eta  busmodel.RawEstimated
		want bool
	}{
		{
			name: "bus still en route",
			eta:  busmodel.RawEstimated{EstimatedTime: 120, SrcUpdateTime: "2026-07-10T07:59:30Z"},
			want: false,
		},
		{
			name: "just past arrival stays arriving through the grace",
			eta:  busmodel.RawEstimated{EstimatedTime: 0, SrcUpdateTime: "2026-07-10T07:59:00Z"},
			want: false,
		},
		{
			name: "feed stopped updating hours ago",
			eta:  busmodel.RawEstimated{EstimatedTime: 60, SrcUpdateTime: "2026-07-10T05:00:00Z"},
			want: true,
		},
		{
			name: "unparseable src time cannot be aged",
			eta:  busmodel.RawEstimated{EstimatedTime: 0, SrcUpdateTime: ""},
			want: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := arrivingExpired(tt.eta, now); got != tt.want {
				t.Fatalf("arrivingExpired() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestBuildBusEtaMap(t *testing.T) {
	t.Run("collisions resolve via pickBusEstimate", func(t *testing.T) {
		eat := []busmodel.RawEstimated{
			{SubRouteUID: "R1", Direction: 0, StopUID: "S1", StopStatus: 1, EstimatedTime: 10},
			{SubRouteUID: "R1", Direction: 0, StopUID: "S1", StopStatus: 0, EstimatedTime: 300},
			{SubRouteUID: "R1", Direction: 0, StopUID: "S2", StopStatus: 1, EstimatedTime: 45},
		}
		m := buildBusEtaMap("Taipei", eat, nil)
		if len(m) != 2 {
			t.Fatalf("len = %d, want 2", len(m))
		}
		got := m[etaKey{"R1", 0, "S1"}]
		if got.StopStatus != 0 || got.EstimatedTime != 300 {
			t.Fatalf("S1 = %+v, want status 0 est 300 (en-route wins)", got)
		}
	})

	t.Run("InterCity canonicalizes subroute suffix", func(t *testing.T) {
		eat := []busmodel.RawEstimated{
			{SubRouteUID: "ABC01", Direction: 9, StopUID: "S1", EstimatedTime: 60},
			{SubRouteUID: "ABC02", Direction: 9, StopUID: "S1", EstimatedTime: 90},
		}
		m := buildBusEtaMap("InterCity", eat, nil)
		if _, ok := m[etaKey{"ABC", 0, "S1"}]; !ok {
			t.Errorf("missing canonical outbound key ABC/0")
		}
		if _, ok := m[etaKey{"ABC", 1, "S1"}]; !ok {
			t.Errorf("missing canonical inbound key ABC/1")
		}
	})

	// Taipei/NewTaipei publish arrivals with RouteUID only. Route 261 (TPE10414)
	// has two subroutes; each must pick up the route-level entry, but only for the
	// stops it actually serves.
	t.Run("route-level entry fans out to the route's subroutes", func(t *testing.T) {
		mp := []busmodel.StationMap{
			{SubRouteUID: "TPE104140", RouteUID: "TPE10414", Direction: 1, StopUID: "S1"},
			{SubRouteUID: "TPE104140", RouteUID: "TPE10414", Direction: 1, StopUID: "S2"},
			{SubRouteUID: "TPE162278", RouteUID: "TPE10414", Direction: 1, StopUID: "S1"},
			{SubRouteUID: "TPE999990", RouteUID: "TPE99999", Direction: 1, StopUID: "S9"},
		}
		eat := []busmodel.RawEstimated{
			{RouteUID: "TPE10414", Direction: 1, StopUID: "S1", StopStatus: 0, EstimatedTime: 240},
		}
		m := buildBusEtaMap("Taipei", eat, mp)
		for _, sub := range []string{"TPE104140", "TPE162278"} {
			got, ok := m[etaKey{sub, 1, "S1"}]
			if !ok {
				t.Fatalf("subroute %s did not pick up the route-level arrival", sub)
			}
			if got.EstimatedTime != 240 {
				t.Errorf("%s estimate = %d, want 240", sub, got.EstimatedTime)
			}
		}
		if _, ok := m[etaKey{"TPE104140", 1, "S2"}]; ok {
			t.Error("fan-out invented an arrival at S2, which the feed never reported")
		}
		if _, ok := m[etaKey{"TPE999990", 1, "S1"}]; ok {
			t.Error("fan-out leaked the arrival to an unrelated route")
		}
	})

	// The loader lands InterCity stops under their canonical UID, so mp must be
	// joined as read. Canonicalizing it a second time strips THB0968 to THB096 and
	// collapses the lettered variant THB0968A onto the base route.
	t.Run("InterCity stop map is joined without a second canonicalization", func(t *testing.T) {
		mp := []busmodel.StationMap{
			{SubRouteUID: "THB0968", RouteUID: "THB0968", Direction: 0, StopUID: "S1"},
			{SubRouteUID: "THB0968A", RouteUID: "THB0968", Direction: 0, StopUID: "S1"},
		}
		eat := []busmodel.RawEstimated{
			{SubRouteUID: "THB096801", RouteUID: "THB0968", Direction: 0, StopUID: "S1", StopStatus: 0, EstimatedTime: 120},
		}
		m := buildBusEtaMap("InterCity", eat, mp)
		got, ok := m[etaKey{"THB0968", 0, "S1"}]
		if !ok {
			t.Fatal("canonical feed key THB0968/0 did not match the stop map")
		}
		if got.EstimatedTime != 120 {
			t.Errorf("estimate = %d, want 120", got.EstimatedTime)
		}
		if _, ok := m[etaKey{"THB0968A", 0, "S1"}]; ok {
			t.Error("the lettered variant picked up the base route's arrival")
		}
	})

	// Tainan sends Direction 255 on schedule-only entries; the subroute UID already
	// names the direction, so the entry belongs to whichever direction mp records.
	t.Run("unknown direction fans out to the stop map's directions", func(t *testing.T) {
		mp := []busmodel.StationMap{
			{SubRouteUID: "TNN111001", RouteUID: "TNN1110", Direction: 1, StopUID: "S1"},
			{SubRouteUID: "TNN111002", RouteUID: "TNN1110", Direction: 0, StopUID: "S1"},
		}
		eat := []busmodel.RawEstimated{
			{SubRouteUID: "TNN111001", RouteUID: "TNN1110", Direction: 255, StopUID: "S1", StopStatus: 1, NextBusTime: "2026-07-31T17:35:00+08:00"},
		}
		m := buildBusEtaMap("Tainan", eat, mp)
		if _, ok := m[etaKey{"TNN111001", 1, "S1"}]; !ok {
			t.Fatal("direction-255 entry did not reach the direction its stop map records")
		}
		if _, ok := m[etaKey{"TNN111002", 0, "S1"}]; ok {
			t.Error("direction-255 entry leaked to the opposite-direction subroute")
		}
	})

	// A feed that does carry SubRouteUID must not also fan out by RouteUID, or one
	// subroute's arrival would be copied onto its siblings.
	t.Run("subroute-level entry does not fan out", func(t *testing.T) {
		mp := []busmodel.StationMap{
			{SubRouteUID: "KEE015801", RouteUID: "KEE0158", Direction: 0, StopUID: "S1"},
			{SubRouteUID: "KEE015802", RouteUID: "KEE0158", Direction: 0, StopUID: "S1"},
		}
		eat := []busmodel.RawEstimated{
			{SubRouteUID: "KEE015801", RouteUID: "KEE0158", Direction: 0, StopUID: "S1", EstimatedTime: 60},
		}
		m := buildBusEtaMap("Keelung", eat, mp)
		if _, ok := m[etaKey{"KEE015802", 0, "S1"}]; ok {
			t.Error("sibling subroute picked up an arrival that named a specific subroute")
		}
	})
}

// An estimate published under another operator's StopUID still belongs to this
// stop; the primary UID is preferred when both are present.
func TestEtaForStopResolvesOperatorAliases(t *testing.T) {
	stop := busmodel.StationMap{
		SubRouteUID:   "THB1234",
		Direction:     0,
		StopUID:       "OP1_S5",
		AliasStopUIDs: []string{"OP2_S5", "OP3_S5"},
	}
	etamap := map[etaKey]busmodel.RawEstimated{
		{"THB1234", 0, "OP3_S5"}: {EstimatedTime: 240},
	}

	got, ok := etaForStop(etamap, stop)
	if !ok || got.EstimatedTime != 240 {
		t.Fatalf("alias lookup = %+v (ok=%v), want the aliased estimate", got, ok)
	}

	etamap[etaKey{"THB1234", 0, "OP1_S5"}] = busmodel.RawEstimated{EstimatedTime: 60}
	if got, _ = etaForStop(etamap, stop); got.EstimatedTime != 60 {
		t.Errorf("primary lookup = %+v, want the stop's own entry to win", got)
	}

	if _, ok := etaForStop(map[etaKey]busmodel.RawEstimated{}, stop); ok {
		t.Error("empty map reported a match")
	}
}

func TestBuildBusPositionMap(t *testing.T) {
	posit := []busmodel.RawPosition{
		{PlateNumb: "AAA-1", SubRouteUID: "R1", Direction: 0, Speed: 42.7, Azimuth: 180},
		{PlateNumb: "AAA-2", SubRouteUID: "R1", Direction: 0, Speed: 0, Azimuth: 90},
		{PlateNumb: "WRONG-WAY", SubRouteUID: "R1", Direction: 1, Speed: 9, Azimuth: 270},
		{PlateNumb: "BBB-1", SubRouteUID: "R2", Direction: 1, Speed: 10, Azimuth: 0},
	}
	posit[0].BusPosition.PositionLon = 121.5
	posit[0].BusPosition.PositionLat = 25.0
	m := buildDirectionAwareBusPositionMap("Taipei", posit, time.Now())
	if len(m["R1\x000"]) != 2 {
		t.Fatalf("R1 direction 0 buses = %d, want 2", len(m["R1\x000"]))
	}
	if len(m["R1\x001"]) != 1 || m["R1\x001"][0].PlateNumb != "WRONG-WAY" {
		t.Fatalf("R1 direction 1 buses = %+v, want WRONG-WAY only", m["R1\x001"])
	}
	if len(m["R2\x001"]) != 1 {
		t.Fatalf("R2 direction 1 buses = %d, want 1", len(m["R2\x001"]))
	}
	first := m["R1\x000"][0]
	if first.PlateNumb != "AAA-1" || first.Speed != 42 || first.Azimuth != 180 {
		t.Errorf("first R1 bus = %+v, want plate AAA-1 speed 42 azimuth 180 (float truncated)", first)
	}
	if first.PositionLon != 121.5 || first.PositionLat != 25.0 {
		t.Errorf("first R1 bus position = (%v,%v), want (121.5,25.0)", first.PositionLon, first.PositionLat)
	}
}

func TestParseGPSTimeUnix(t *testing.T) {
	// +08:00 offset (the common TDX form) and a zone-less string read as Taipei
	// both resolve to the same instant; junk and empty fall back to 0.
	want := time.Date(2026, 7, 13, 8, 30, 0, 0, pipeline.Taipei).Unix()
	cases := map[string]int64{
		"2026-07-13T08:30:00+08:00": want,
		"2026-07-13T08:30:00":       want,
		"2026-07-13 08:30:00":       want,
		"":                          0,
		"not-a-time":                0,
	}
	for in, exp := range cases {
		if got := parseGPSTimeUnix(in); got != exp {
			t.Errorf("parseGPSTimeUnix(%q) = %d, want %d", in, got, exp)
		}
	}
}

func TestBuildTotalStops(t *testing.T) {
	mp := []busmodel.StationMap{
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1"},
		{SubRouteUID: "R1", Direction: 0, StopUID: "S2"},
		{SubRouteUID: "R1", Direction: 0, StopUID: "S3"},
		{SubRouteUID: "R2", Direction: 1, StopUID: "S1"},
	}
	got := buildTotalStops(mp)
	if got["R1"] != 3 {
		t.Errorf("R1 = %d, want 3", got["R1"])
	}
	if got["R2"] != 1 {
		t.Errorf("R2 = %d, want 1", got["R2"])
	}
}

func TestCollectFillKeys(t *testing.T) {
	mp := []busmodel.StationMap{
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1"}, // status 1, gap → fill
		{SubRouteUID: "R1", Direction: 0, StopUID: "S2"}, // status 0, en route → fill
		{SubRouteUID: "R1", Direction: 0, StopUID: "S3"}, // status 1 with NextBusTime → skip
		{SubRouteUID: "R2", Direction: 1, StopUID: "S1"}, // no eta entry → skip
	}
	etamap := map[etaKey]busmodel.RawEstimated{
		{"R1", 0, "S1"}: {StopStatus: 1, NextBusTime: ""},
		{"R1", 0, "S2"}: {StopStatus: 0},
		{"R1", 0, "S3"}: {StopStatus: 1, NextBusTime: "2026-07-10T08:05:00Z"},
	}
	keys, uids := collectFillKeys(mp, etamap)
	if len(keys) != 2 {
		t.Fatalf("fillKeys = %d (%v), want 2", len(keys), keys)
	}
	for _, k := range keys {
		if k != (predict.RouteDirKey{SubRouteUID: "R1", Direction: 0}) {
			t.Errorf("unexpected fill key %+v", k)
		}
	}
	if len(uids) != 1 || !uids["R1"] {
		t.Errorf("fillUIDs = %v, want {R1}", uids)
	}
}

func TestBuildUpstreamObs(t *testing.T) {
	now := time.Date(2026, 7, 10, 8, 0, 0, 0, time.UTC)
	// baselineFor stub: S1 has a baseline 100s ahead of now; S9 has none (zero).
	baselineFor := func(b busmodel.StationMap, uid string, dir int32) time.Time {
		if b.StopUID == "S1" {
			return now.Add(100 * time.Second)
		}
		return time.Time{}
	}
	mp := []busmodel.StationMap{
		{SubRouteUID: "R1", Direction: 0, StopUID: "S1", StopSequence: 3}, // en route, has baseline → obs
		{SubRouteUID: "R1", Direction: 0, StopUID: "S9", StopSequence: 5}, // en route, zero baseline → skip
		{SubRouteUID: "R1", Direction: 0, StopUID: "S2", StopSequence: 4}, // status 1 → skip
	}
	etamap := map[etaKey]busmodel.RawEstimated{
		{"R1", 0, "S1"}: {StopStatus: 0, EstimatedTime: 160}, // observed arrival now+160
		{"R1", 0, "S9"}: {StopStatus: 0, EstimatedTime: 60},
		{"R1", 0, "S2"}: {StopStatus: 1},
	}
	got := buildUpstreamObs(mp, etamap, now, baselineFor)
	obs := got[predict.RouteDirKey{SubRouteUID: "R1", Direction: 0}]
	if len(obs) != 1 {
		t.Fatalf("obs count = %d, want 1", len(obs))
	}
	// delay = observedArrival(now+160) - baseline(now+100) = 60s late.
	if obs[0].StopSequence != 3 || obs[0].DelaySeconds != 60 {
		t.Errorf("obs = %+v, want seq 3 delay 60", obs[0])
	}
}

// TDX keeps a vehicle's last A1 record for two hours; only the fresh ones may be
// published, and a record whose GPSTime does not parse carries no age to judge.
func TestBuildBusPositionMapDropsStaleGPS(t *testing.T) {
	now := time.Date(2026, 7, 10, 8, 0, 0, 0, pipeline.Taipei)
	posit := []busmodel.RawPosition{
		{PlateNumb: "FRESH", SubRouteUID: "R1", GPSTime: now.Add(-1 * time.Minute).Format(time.RFC3339)},
		{PlateNumb: "STALE", SubRouteUID: "R1", GPSTime: now.Add(-2 * time.Hour).Format(time.RFC3339)},
		{PlateNumb: "NO-CLOCK", SubRouteUID: "R1", GPSTime: ""},
	}
	buses := buildDirectionAwareBusPositionMap("Taipei", posit, now)["R1\x000"]
	if len(buses) != 2 {
		t.Fatalf("published buses = %d, want 2 (fresh + unparseable)", len(buses))
	}
	for _, bus := range buses {
		if bus.PlateNumb == "STALE" {
			t.Error("a two-hour-old GPS record was published")
		}
	}
}

// TDX's own system refuses to estimate arrivals from a vehicle that ended its
// duty or left service, so neither may be attributed to a stop.
func TestNearestBusSkipsOutOfService(t *testing.T) {
	stopLat, stopLon := 25.0400, 121.5300
	buses := []*models.BusPosition{
		{PlateNumb: "REFUELLING", PositionLat: 25.0401, PositionLon: 121.5301, BusStatus: 99, DutyStatus: 2},
		{PlateNumb: "OFF-DUTY", PositionLat: 25.0402, PositionLon: 121.5302, DutyStatus: 2},
		{PlateNumb: "IN-SERVICE", PositionLat: 25.0500, PositionLon: 121.5400, Speed: 20},
	}

	t.Run("nearest in-service vehicle wins over a closer out-of-service one", func(t *testing.T) {
		plate, speed, dist := nearestBus(stopLat, stopLon, buses)
		if plate == nil || *plate != "IN-SERVICE" {
			t.Fatalf("plate = %v, want IN-SERVICE", plate)
		}
		if speed == nil || *speed != 20 || dist == nil || *dist <= 0 {
			t.Errorf("speed = %v dist = %v, want 20 and positive metres", speed, dist)
		}
	})

	t.Run("only out-of-service vehicles returns nil", func(t *testing.T) {
		plate, speed, dist := nearestBus(stopLat, stopLon, buses[:2])
		if plate != nil || speed != nil || dist != nil {
			t.Errorf("want all nil, got %v %v %v", plate, speed, dist)
		}
	})
}

func TestCountFrozenEstimates(t *testing.T) {
	stamp := func(t time.Time) string { return t.Format(time.RFC3339) }
	base := time.Date(2026, 7, 10, 8, 0, 0, 0, pipeline.Taipei)
	eat := []busmodel.RawEstimated{
		{SrcUpdateTime: stamp(base), DataTime: stamp(base.Add(-10 * time.Second))},
		{SrcUpdateTime: stamp(base), DataTime: stamp(base.Add(-5 * time.Minute))},
		{SrcUpdateTime: stamp(base), DataTime: stamp(base.Add(-31 * time.Minute))},
		{SrcUpdateTime: stamp(base)},
		{DataTime: stamp(base)},
	}
	if got := countFrozenEstimates(eat); got != 2 {
		t.Errorf("frozen count = %d, want 2", got)
	}
}

func TestNormalizeArrivalPlate(t *testing.T) {
	tests := []struct {
		name  string
		plate string
		want  string
	}{
		{name: "trims and upper-cases", plate: " kka-1234 ", want: "KKA-1234"},
		{name: "passed-stop marker is not a plate", plate: "-1", want: ""},
		{name: "padded passed-stop marker", plate: " -1 ", want: ""},
		{name: "empty stays empty", plate: "", want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := normalizeArrivalPlate(tt.plate); got != tt.want {
				t.Errorf("normalizeArrivalPlate(%q) = %q, want %q", tt.plate, got, tt.want)
			}
		})
	}
}

func TestNearestBus(t *testing.T) {
	stopLat, stopLon := 25.0400, 121.5300
	buses := []*models.BusPosition{
		{PlateNumb: "FAR-1", PositionLat: 25.1000, PositionLon: 121.6000, Speed: 30},
		{PlateNumb: "NEAR-1", PositionLat: 25.0405, PositionLon: 121.5305, Speed: 12},
	}

	t.Run("picks nearest vehicle", func(t *testing.T) {
		plate, speed, dist := nearestBus(stopLat, stopLon, buses)
		if plate == nil || *plate != "NEAR-1" {
			t.Fatalf("plate = %v, want NEAR-1", plate)
		}
		if speed == nil || *speed != 12 {
			t.Errorf("speed = %v, want 12", speed)
		}
		if dist == nil || *dist <= 0 {
			t.Errorf("dist = %v, want positive metres", dist)
		}
	})

	t.Run("no buses returns nil", func(t *testing.T) {
		plate, speed, dist := nearestBus(stopLat, stopLon, nil)
		if plate != nil || speed != nil || dist != nil {
			t.Errorf("want all nil, got %v %v %v", plate, speed, dist)
		}
	})

	t.Run("stop without coordinate returns nil", func(t *testing.T) {
		plate, speed, dist := nearestBus(0, stopLon, buses)
		if plate != nil || speed != nil || dist != nil {
			t.Errorf("want all nil for lat==0, got %v %v %v", plate, speed, dist)
		}
	})
}

func TestComputeArrivalUnix(t *testing.T) {
	now := time.Date(2026, 7, 10, 8, 0, 0, 0, time.UTC)
	tests := []struct {
		name        string
		status      uint8
		est         int32
		nextBusTime string
		want        int64
	}{
		{name: "status 0 positive estimate", status: 0, est: 90, nextBusTime: "", want: now.Add(90 * time.Second).Unix()},
		{name: "status 0 non-positive estimate stays zero", status: 0, est: 0, nextBusTime: "", want: 0},
		{name: "status 1 valid next bus time", status: 1, est: 0, nextBusTime: "2026-07-10T08:05:00Z", want: time.Date(2026, 7, 10, 8, 5, 0, 0, time.UTC).Unix()},
		{name: "status 1 empty next bus time stays zero", status: 1, est: 0, nextBusTime: "", want: 0},
		{name: "status 1 unparseable next bus time stays zero", status: 1, est: 0, nextBusTime: "not-a-time", want: 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := computeArrivalUnix(tt.status, tt.est, tt.nextBusTime, now); got != tt.want {
				t.Fatalf("computeArrivalUnix() = %d, want %d", got, tt.want)
			}
		})
	}
}
