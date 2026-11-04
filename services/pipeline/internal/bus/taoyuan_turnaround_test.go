package bus

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/protobuf/proto"
)

// 261 as TDX publishes it after Taoyuan's overhaul, trimmed: one direction out
// to 銘傳設計大樓 and back, ending somewhere other than where it started.
func route261() *models.BusSubroute {
	names := []string{"統領百貨", "德明路口", "銘傳資管大樓", "銘傳設計大樓", "銘傳郵政代辦所", "德明路口", "桃園公車站"}
	stops := make([]*models.BusStop, len(names))
	for i, n := range names {
		stops[i] = &models.BusStop{StopUID: "TAO" + string(rune('A'+i)), StopName: n, StopSequence: int32(i + 1), PositionLon: float64(i), PositionLat: 0}
	}
	return &models.BusSubroute{
		SubRouteUID: "TAO2610", DepartureStopName: "統領百貨", DestinationStopName: "桃園公車站",
		Directions: map[int32]*models.Direction{0: {
			DepartureStopName: "統領百貨", DestinationStopName: "桃園公車站",
			Geometry: "LINESTRING(0 0,1 0,2 0,3 0,4 0,5 0,6 0)",
			Stops:    stops,
			Schedules: []*models.Bus_Schedule{
				{IsTimetable: true, Tripid: "t1"},
				{IsTimetable: false, Tripid: "h1"},
			},
		}},
	}
}

func TestTaoyuanTurnaroundRows(t *testing.T) {
	body := []byte(`<?xml version="1.0" encoding="utf-8"?>
<BusDynInfo><EssentialInfo><UpdateTime>2026-11-04 03:30:07</UpdateTime></EssentialInfo><BusInfo>
<Route ID="2610" nameZh="261" IsCircular="1" backStopId="8610" backZh="銘傳設計大樓"/>
<Route ID="1050" nameZh="T105" IsCircular="1" backStopId="" backZh=""/>
<Route ID=" " nameZh="blank"/>
</BusInfo></BusDynInfo>`)
	feed, rows, err := taoyuanTurnaroundRows(body)
	if err != nil {
		t.Fatal(err)
	}
	if feed.UpdateTime != "2026-11-04 03:30:07" {
		t.Fatalf("UpdateTime = %q", feed.UpdateTime)
	}
	want := []taoyuanTurnaroundRow{
		{SubRouteUID: "TAO2610", IsCircular: true, BackStopUID: "TAO8610"},
		{SubRouteUID: "TAO1050", IsCircular: true},
	}
	if len(rows) != len(want) || rows[0] != want[0] || rows[1] != want[1] {
		t.Fatalf("rows = %#v, want %#v", rows, want)
	}
}

func TestTaoyuanTurnaroundRowsRejectsBadFeeds(t *testing.T) {
	for name, body := range map[string]string{
		"not xml":   "{}",
		"no routes": `<BusDynInfo><BusInfo></BusInfo></BusDynInfo>`,
	} {
		if _, _, err := taoyuanTurnaroundRows([]byte(body)); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestLandTaoyuanTurnaroundsFetchFailures(t *testing.T) {
	for name, handler := range map[string]http.HandlerFunc{
		"http error": func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusBadGateway) },
		"bad body":   func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("<x")) },
	} {
		srv := httptest.NewServer(handler)
		err := LandTaoyuanTurnarounds(context.Background(), resty.New().SetBaseURL(srv.URL))
		srv.Close()
		if err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	if err := LandTaoyuanTurnarounds(context.Background(), resty.New().SetBaseURL("http://127.0.0.1:1")); err == nil {
		t.Error("unreachable: want an error")
	}
}

func TestDecodeTurnarounds(t *testing.T) {
	got, err := decodeTurnarounds([]byte(`[{"subrouteuid":"TAO2610","iscircular":true,"backstopuid":"TAO8610"},{"subrouteuid":"TAO1050","iscircular":true,"backstopuid":""}]`))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got["TAO2610"] != "TAO8610" {
		t.Fatalf("got %v, want only the route with a turnaround", got)
	}
	if _, err := decodeTurnarounds([]byte("{")); err == nil {
		t.Fatal("want an error for a malformed body")
	}
}

func TestReadTurnaroundsOnlyForTaoyuan(t *testing.T) {
	b := &busSnapshotBuilder{snapshot: &busCitySnapshot{city: "Taipei"}}
	if err := b.readTurnarounds(); err != nil || b.snapshot.turnarounds != nil {
		t.Fatalf("Taipei: err=%v turnarounds=%v, want untouched", err, b.snapshot.turnarounds)
	}
}

func TestTurnaroundSequence(t *testing.T) {
	sub := route261()
	if got := turnaroundSequence(sub, "TAOD"); got != 4 {
		t.Fatalf("261 turnaround = %d, want 4 (銘傳設計大樓)", got)
	}
	if got := turnaroundSequence(route261(), "TAOB"); got != 2 {
		t.Fatalf("second-stop turnaround = %d, want 2", got)
	}
	if got := turnaroundSequence(route261(), "TAOF"); got != 6 {
		t.Fatalf("second-to-last turnaround = %d, want 6", got)
	}
	cases := map[string]struct {
		sub  *models.BusSubroute
		back string
	}{
		"no turnaround":   {route261(), ""},
		"unknown stop":    {route261(), "TAOZ"},
		"first stop":      {route261(), "TAOA"},
		"last stop":       {route261(), "TAOG"},
		"twice in a loop": {withStop(route261(), 5, "TAOD"), "TAOD"},
		"real direction 1": {func() *models.BusSubroute {
			s := route261()
			s.Directions[1] = &models.Direction{}
			return s
		}(), "TAOD"},
		"no direction 0": {&models.BusSubroute{Directions: map[int32]*models.Direction{1: {}}}, "TAOD"},
	}
	for name, c := range cases {
		if got := turnaroundSequence(c.sub, c.back); got != 0 {
			t.Errorf("%s: got %d, want 0", name, got)
		}
	}
}

func withStop(sub *models.BusSubroute, i int, uid string) *models.BusSubroute {
	sub.Directions[0].Stops[i].StopUID = uid
	return sub
}

func TestSplitAtTurnaround(t *testing.T) {
	sub := route261()
	view := splitAtTurnaround(sub, 4)

	out, back := view.Directions[0], view.Directions[1]
	if names(out) != "統領百貨,德明路口,銘傳資管大樓,銘傳設計大樓" {
		t.Errorf("去程 = %s", names(out))
	}
	if names(back) != "銘傳設計大樓,銘傳郵政代辦所,德明路口,桃園公車站" {
		t.Errorf("返程 = %s", names(back))
	}
	if out.DepartureStopName != "統領百貨" || out.DestinationStopName != "銘傳設計大樓" {
		t.Errorf("去程 endpoints = %s → %s", out.DepartureStopName, out.DestinationStopName)
	}
	if back.DepartureStopName != "銘傳設計大樓" || back.DestinationStopName != "桃園公車站" {
		t.Errorf("返程 endpoints = %s → %s", back.DepartureStopName, back.DestinationStopName)
	}
	if back.Stops[0].StopSequence != 4 || back.Stops[3].StopSequence != 7 {
		t.Errorf("返程 must keep TDX sequences, got %d..%d", back.Stops[0].StopSequence, back.Stops[3].StopSequence)
	}
	if out.Geometry != "LINESTRING(0 0,1 0,2 0,3 0)" || back.Geometry != "LINESTRING(3 0,4 0,5 0,6 0)" {
		t.Errorf("geometry = %q / %q", out.Geometry, back.Geometry)
	}
	if len(out.Schedules) != 2 || len(back.Schedules) != 1 || back.Schedules[0].IsTimetable {
		t.Errorf("schedules: 去程 keeps all, 返程 only headway; got %d / %d", len(out.Schedules), len(back.Schedules))
	}
	if len(sub.Directions) != 1 || len(sub.Directions[0].Stops) != 7 {
		t.Fatal("the loader's own subroute must stay one loop")
	}
}

func names(d *models.Direction) string {
	s := ""
	for i, st := range d.Stops {
		if i > 0 {
			s += ","
		}
		s += st.StopName
	}
	return s
}

func TestSplitLineString(t *testing.T) {
	line := "LINESTRING(0 0,1 0,2 0,3 0)"
	if a, b := splitLineString(line, 1.1, 0.1); a != "LINESTRING(0 0,1 0)" || b != "LINESTRING(1 0,2 0,3 0)" {
		t.Errorf("split = %q / %q", a, b)
	}
	diagonal := "LINESTRING(0 0,1 1,2 2,3 3)"
	if a, b := splitLineString(diagonal, 1.1, 0.9); a != "LINESTRING(0 0,1 1)" || b != "LINESTRING(1 1,2 2,3 3)" {
		t.Errorf("diagonal split = %q / %q", a, b)
	}
	for name, c := range map[string]struct {
		wkt      string
		lon, lat float64
	}{
		"multi":      {"MULTILINESTRING((0 0,1 0))", 0, 0},
		"unclosed":   {"LINESTRING(0 0,1 0,2 0", 1, 0},
		"no prefix":  {"POINT(0 0,1 0,2 0)", 1, 0},
		"garbage":    {"LINESTRING(0 0,x y,2 0)", 1, 0},
		"at start":   {line, -1, 0},
		"at the end": {line, 9, 0},
	} {
		if a, b := splitLineString(c.wkt, c.lon, c.lat); a != c.wkt || b != c.wkt {
			t.Errorf("%s: got %q / %q, want the line whole", name, a, b)
		}
	}
}

func TestNullableSequence(t *testing.T) {
	if nullableSequence(0) != nil {
		t.Error("0 must store NULL")
	}
	if p := nullableSequence(4); p == nil || *p != 4 {
		t.Error("4 must store 4")
	}
}

func TestBuildSubrouteRowsSplitsOnlyThePayload(t *testing.T) {
	s := &busCitySnapshot{subroutes: map[string]*models.BusSubroute{"TAO2610": route261()}, turnarounds: map[string]string{"TAO2610": "TAOD"}}
	if err := s.buildSubrouteRows("TAO2610"); err != nil {
		t.Fatal(err)
	}
	row := s.staticRows[0]
	if seq, ok := row[len(row)-1].(*int32); !ok || seq == nil || *seq != 4 {
		t.Fatalf("turnaround column = %#v, want 4", row[len(row)-1])
	}
	if got := len(s.stopMapRows); got != 7 {
		t.Fatalf("stop map rows = %d, want the 7 TDX stops untouched", got)
	}
}

const taoyuanRouteXML = `<?xml version="1.0" encoding="utf-8"?>
<BusDynInfo><EssentialInfo><UpdateTime>2026-11-04 03:30:07</UpdateTime></EssentialInfo><BusInfo>
<Route ID="2610" nameZh="261" IsCircular="1" backStopId="8610" backZh="銘傳設計大樓"/>
</BusInfo></BusDynInfo>`

func taoyuanRouteServer(t *testing.T) *resty.Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != _taoyuanRouteEndpoint || r.URL.Query().Get("$format") != "XML" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(taoyuanRouteXML))
	}))
	t.Cleanup(srv.Close)
	return resty.New().SetBaseURL(srv.URL)
}

func TestLandTaoyuanTurnaroundsNeedsTheRawDB(t *testing.T) {
	previous := raw.DB
	raw.DB = nil
	t.Cleanup(func() { raw.DB = previous })
	if err := LandTaoyuanTurnarounds(context.Background(), taoyuanRouteServer(t)); err == nil {
		t.Fatal("landing without a raw DB was accepted")
	}
}

func TestLandTaoyuanTurnaroundsWritesRawPartition(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required")
		}
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	previous := raw.DB
	raw.DB = pool
	t.Cleanup(func() {
		raw.DB = previous
		_, _ = pool.Exec(context.Background(), `DELETE FROM raw_tdx.bus_taoyuanroute WHERE city='Taoyuan'`)
		_, _ = pool.Exec(context.Background(), `DELETE FROM raw_tdx.landing_state WHERE table_name='bus_taoyuanroute'`)
	})
	if err := LandTaoyuanTurnarounds(ctx, taoyuanRouteServer(t)); err != nil {
		t.Fatal(err)
	}
	var uid, back, marker string
	var circular bool
	if err := pool.QueryRow(ctx, `SELECT subrouteuid, iscircular, backstopuid FROM raw_tdx.bus_taoyuanroute WHERE city='Taoyuan'`).Scan(&uid, &circular, &back); err != nil {
		t.Fatal(err)
	}
	if uid != "TAO2610" || !circular || back != "TAO8610" {
		t.Fatalf("landed row = %s / %v / %s", uid, circular, back)
	}
	if err := pool.QueryRow(ctx, `SELECT last_modified FROM raw_tdx.landing_state WHERE table_name='bus_taoyuanroute' AND partition_value='Taoyuan'`).Scan(&marker); err != nil {
		t.Fatal(err)
	}
	if marker != "taoyuanroute:2026-11-04 03:30:07" {
		t.Fatalf("marker = %q", marker)
	}
}

func TestReadTurnaroundsForTaoyuan(t *testing.T) {
	const key = _taoyuanRouteTable + "|" + _taoyuanCity
	fresh := func(body string) *busSnapshotSource {
		return &busSnapshotSource{
			bodies: map[string][]byte{key: []byte(body)},
			times:  map[string]time.Time{key: time.Now()},
			cycles: map[string]string{key: "own-cycle"},
		}
	}
	read := func(src *busSnapshotSource) *busCitySnapshot {
		b := &busSnapshotBuilder{ctx: context.Background(), source: src, snapshot: &busCitySnapshot{city: _taoyuanCity, landingCycle: "bus-cycle"}}
		if err := b.readTurnarounds(); err != nil {
			t.Fatalf("readTurnarounds must never fail the city: %v", err)
		}
		return b.snapshot
	}
	core, observed := observer.New(zap.WarnLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	got := read(fresh(`[{"subrouteuid":"TAO2610","iscircular":true,"backstopuid":"TAO8610"}]`))
	if observed.Len() != 0 {
		t.Fatalf("a good landing logged %d warnings", observed.Len())
	}
	if got.turnarounds["TAO2610"] != "TAO8610" || got.landingCycle != "bus-cycle" {
		t.Fatalf("turnarounds = %v, cycle = %q; want the stop without adopting its cycle", got.turnarounds, got.landingCycle)
	}
	stale := fresh(`[{"subrouteuid":"TAO2610","backstopuid":"TAO8610"}]`)
	stale.times[key] = time.Now().Add(-raw.StaleAfter - time.Hour)
	for name, src := range map[string]*busSnapshotSource{"stale": stale, "malformed": fresh(`{`)} {
		before := observed.Len()
		if got := read(src); got.turnarounds != nil {
			t.Errorf("%s: turnarounds = %v, want none", name, got.turnarounds)
		}
		if observed.Len() != before+1 {
			t.Errorf("%s: want one skipped warning", name)
		}
	}
}

func TestBuildSubrouteRowsSplitsAtSequenceOne(t *testing.T) {
	sub := route261()
	for i, st := range sub.Directions[0].Stops {
		st.StopSequence = int32(i)
	}
	s := &busCitySnapshot{subroutes: map[string]*models.BusSubroute{"TAO2610": sub}, turnarounds: map[string]string{"TAO2610": "TAOB"}}
	if err := s.buildSubrouteRows("TAO2610"); err != nil {
		t.Fatal(err)
	}
	row := s.staticRows[0]
	var view models.BusSubroute
	if err := proto.Unmarshal(row[7].([]byte), &view); err != nil {
		t.Fatal(err)
	}
	if seq := row[8].(*int32); seq == nil || *seq != 1 || len(view.Directions) != 2 {
		t.Fatalf("turnaround %v, %d directions; want a split at sequence 1", row[8], len(view.Directions))
	}
}
