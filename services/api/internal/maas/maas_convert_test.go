package maas

// MOTIS/TDX response conversion: walk-route geometry via OSRM, section fares,
// and the cache key. Split out of maas_test.go for size; both files are the
// same package and share its fakes.

import (
	"context"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/go-resty/resty/v2"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/pashagolub/pgxmock/v4"
)

func TestWalkRouteFallsBackWithoutOSRM(t *testing.T) {
	// A nil client or zero coordinates must report ok=false so the caller keeps
	// the fixed TDX walk estimate and leaves the path and steps empty.
	from := &pb.Location{Lat: 25.0, Lng: 121.5}
	to := &pb.Location{Lat: 25.1, Lng: 121.6}
	if _, _, _, ok := walkRoute(context.Background(), nil, from, to); ok {
		t.Fatal("nil OSRM client must fall back")
	}
	zero := &pb.Location{}
	if _, _, _, ok := walkRoute(context.Background(), resty.New(), zero, to); ok {
		t.Fatal("zero origin must fall back")
	}
	if _, _, _, ok := walkRoute(context.Background(), resty.New(), from, zero); ok {
		t.Fatal("zero destination must fall back")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// osrmClientReturning builds a resty client whose transport short-circuits every
// request with a canned response, so the OSRM URL (which points at the internal
// osrm:5000 host) never has to resolve.
func osrmClientReturning(status int, body string) *resty.Client {
	c := resty.New()
	c.SetTransport(roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: status,
			Body:       io.NopCloser(strings.NewReader(body)),
			Header:     http.Header{"Content-Type": []string{"application/json"}},
		}, nil
	}))
	return c
}

const _osrmTransferRoute = `{
  "code":"Ok",
  "routes":[{
    "duration":222.5,
    "geometry":{"coordinates":[[121.50,25.00],[121.51,25.01],[121.52,25.02]]},
    "legs":[{"steps":[
      {"distance":50,"duration":40,"name":"忠孝東路四段","maneuver":{"type":"depart","modifier":"","location":[121.50,25.00]}},
      {"distance":30,"duration":25,"name":"市民大道三段","maneuver":{"type":"turn","modifier":"left","location":[121.51,25.01]}},
      {"distance":0,"duration":0,"name":"","maneuver":{"type":"arrive","modifier":"","location":[121.52,25.02]}}
    ]}]
  }]
}`

// A transfer walk (a middle section, not first/last) must get its TDX duration
// replaced by the OSRM time and gain the geometry plus composed steps.
func TestConvertWalkRouteMapsTransferSection(t *testing.T) {
	api := &tdxAPIResponse{}
	api.Data.Routes = []tdxRoute{{
		Sections: []tdxSection{
			{Type: "transit", Transport: tdxTransport{Mode: "BUS"},
				Departure: tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.00, Lng: 121.50}}},
				Arrival:   tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.00, Lng: 121.50}}}},
			{Type: "pedestrian", Transport: tdxTransport{Mode: "pedestrian"},
				TravelSummary: tdxSummary{Duration: 600},
				Departure:     tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.00, Lng: 121.50}}},
				Arrival:       tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.02, Lng: 121.52}}}},
			{Type: "transit", Transport: tdxTransport{Mode: "BUS"},
				Departure: tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.02, Lng: 121.52}}},
				Arrival:   tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.02, Lng: 121.52}}}},
		},
	}}

	out := convert(context.Background(), nil, osrmClientReturning(200, _osrmTransferRoute), api)
	walk := out.Routes[0].Sections[1]
	if walk.TravelSummary.Duration != 222 {
		t.Fatalf("duration = %d, want 222 (OSRM time)", walk.TravelSummary.Duration)
	}
	if len(walk.WalkPath) != 3 {
		t.Fatalf("walkPath len = %d, want 3", len(walk.WalkPath))
	}
	if walk.WalkPath[0].Lat != 25.00 || walk.WalkPath[0].Lng != 121.50 {
		t.Fatalf("first path point = %v, want lat 25.00 lng 121.50", walk.WalkPath[0])
	}
	wantSteps := []string{"沿忠孝東路四段出發", "左轉進入市民大道三段", "抵達目的地"}
	if len(walk.WalkSteps) != len(wantSteps) {
		t.Fatalf("walkSteps len = %d, want %d", len(walk.WalkSteps), len(wantSteps))
	}
	for i, want := range wantSteps {
		if walk.WalkSteps[i].Instruction != want {
			t.Fatalf("step[%d] = %q, want %q", i, walk.WalkSteps[i].Instruction, want)
		}
	}
	if walk.WalkSteps[1].ManeuverType != "turn" || walk.WalkSteps[1].Modifier != "left" {
		t.Fatalf("raw maneuver not preserved: %+v", walk.WalkSteps[1])
	}
}

// An OSRM failure (non-Ok response) leaves the walk section untouched: the TDX
// duration stays and no path or steps are attached. The plan never fails.
func TestConvertWalkRouteFailureLeavesSectionUntouched(t *testing.T) {
	api := &tdxAPIResponse{}
	api.Data.Routes = []tdxRoute{{
		Sections: []tdxSection{
			{Type: "pedestrian", Transport: tdxTransport{Mode: "pedestrian"},
				TravelSummary: tdxSummary{Duration: 600},
				Departure:     tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.00, Lng: 121.50}}},
				Arrival:       tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.02, Lng: 121.52}}}},
		},
	}}

	out := convert(context.Background(), nil, osrmClientReturning(500, `{"code":"NoRoute"}`), api)
	walk := out.Routes[0].Sections[0]
	if walk.TravelSummary.Duration != 600 {
		t.Fatalf("duration = %d, want 600 (TDX kept)", walk.TravelSummary.Duration)
	}
	if len(walk.WalkPath) != 0 || len(walk.WalkSteps) != 0 {
		t.Fatalf("failed OSRM must leave path/steps empty: path=%d steps=%d",
			len(walk.WalkPath), len(walk.WalkSteps))
	}
}

func TestConvertWalkRoutesAreBoundedConcurrentAndOrderStable(t *testing.T) {
	const walkCount = 9
	var active, peak int32
	client := resty.New()
	client.SetTransport(roundTripFunc(func(request *http.Request) (*http.Response, error) {
		current := atomic.AddInt32(&active, 1)
		defer atomic.AddInt32(&active, -1)
		for {
			observed := atomic.LoadInt32(&peak)
			if current <= observed || atomic.CompareAndSwapInt32(&peak, observed, current) {
				break
			}
		}
		var fromLng float64
		_, _ = fmt.Sscanf(strings.TrimPrefix(request.URL.Path, "/route/v1/foot/"), "%f,", &fromLng)
		index := int(math.Round((fromLng - 121) * 100))
		time.Sleep(time.Duration(walkCount-index) * 5 * time.Millisecond)
		body := fmt.Sprintf(`{"code":"Ok","routes":[{"duration":%d,"geometry":{"coordinates":[[%f,25],[%f,25.01]]},"legs":[]}]}`,
			100+index, fromLng, fromLng+0.001)
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(body)),
			Header:     http.Header{"Content-Type": []string{"application/json"}},
		}, nil
	}))

	api := &tdxAPIResponse{}
	sections := make([]tdxSection, walkCount)
	for index := range sections {
		lng := 121 + float64(index)/100
		sections[index] = tdxSection{
			Type:          "pedestrian",
			Transport:     tdxTransport{Mode: "pedestrian"},
			TravelSummary: tdxSummary{Duration: 600},
			Departure:     tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25, Lng: lng}}},
			Arrival:       tdxPlaceInfo{Place: tdxPlace{Location: tdxLocation{Lat: 25.01, Lng: lng + 0.001}}},
		}
	}
	api.Data.Routes = []tdxRoute{{Sections: sections}}

	out := convert(context.Background(), nil, client, api)
	if got := atomic.LoadInt32(&peak); got <= 1 || got > 4 {
		t.Fatalf("peak OSRM concurrency = %d, want 2..4", got)
	}
	for index, section := range out.GetRoutes()[0].GetSections() {
		if got, want := section.GetTravelSummary().GetDuration(), int64(100+index); got != want {
			t.Fatalf("section %d duration = %d, want %d (results must retain input order)", index, got, want)
		}
	}
}

// clampInt guards the TDX plan-request parameters; a wrong bound sends invalid
// values upstream, a broken zero-default breaks every old client that omits
// the field.
func TestClampInt(t *testing.T) {
	tests := []struct {
		name                   string
		v, min, max, def, want int32
	}{
		{"unset falls back to default when 0 invalid", 0, 1, 10, 5, 5},
		{"zero kept when 0 within range", 0, 0, 10, 5, 0},
		{"zero kept when range spans negative", 0, -5, 5, 3, 0},
		{"below min clamps up", -3, 1, 10, 5, 1},
		{"above max clamps down", 99, 1, 10, 5, 10},
		{"in range passes through", 7, 1, 10, 5, 7},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := clampInt(tt.v, tt.min, tt.max, tt.def); got != tt.want {
				t.Fatalf("clampInt(%d,%d,%d,%d) = %d, want %d", tt.v, tt.min, tt.max, tt.def, got, tt.want)
			}
		})
	}
}

// A cache-key collision between different plan requests would serve one user
// another user's journey plan; identical requests must hit the same key or the
// cache never helps.
func TestMaasKeyIdentityAndCollision(t *testing.T) {
	base := func() *pb.MaasPlanRequest {
		return &pb.MaasPlanRequest{
			FromLat: 25.0478, FromLon: 121.5170, ToLat: 25.0330, ToLon: 121.5654,
			Date: "2026-07-11", Time: "08:00", Top: 5,
		}
	}
	first, second := maasKey(base()), maasKey(base())
	if first != second {
		t.Fatal("identical requests must produce the same cache key")
	}
	mutations := map[string]func(r *pb.MaasPlanRequest){
		"destination": func(r *pb.MaasPlanRequest) { r.ToLat += 0.001 },
		"date":        func(r *pb.MaasPlanRequest) { r.Date = "2026-07-12" },
		"arrive_by":   func(r *pb.MaasPlanRequest) { r.ArriveBy = true },
		"modes":       func(r *pb.MaasPlanRequest) { r.TransitModes = []int32{3} },
	}
	seen := map[string]string{maasKey(base()): "base"}
	for name, mutate := range mutations {
		r := base()
		mutate(r)
		key := maasKey(r)
		if prev, dup := seen[key]; dup {
			t.Fatalf("cache key collision between %q and %q", name, prev)
		}
		seen[key] = name
	}
}

func TestBatchSectionFaresPicksFullTraFare(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("f.ticket_type = '成復'").
		WithArgs([]int32{0}, []string{"rail"}, []string{"臺北"}, []string{"臺中"}).
		WillReturnRows(pgxmock.NewRows([]string{"section_index", "fare"}).
			AddRow(int32(0), int32(375)))

	section := &pb.Section{}
	route := &pb.Route{}
	src := tdxSection{}
	src.Transport.Mode = "RAIL"
	src.Departure.Place.Name = "臺北"
	src.Arrival.Place.Name = "臺中"

	batchSectionFares(context.Background(), db, []maasSectionRef{
		{index: 0, source: src, target: section, route: route},
	})

	if section.Fare != 375 || route.TotalFare != 375 {
		t.Fatalf("fare = %d, total = %d, want 375 both", section.Fare, route.TotalFare)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
