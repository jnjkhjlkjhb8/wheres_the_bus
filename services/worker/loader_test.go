package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/raw"
	"google.golang.org/protobuf/proto"
)

// fakeLoadSource serves fixed JSON per (table,partVal) and a fixed fetched_at.
// It is the pipeline.LoadSource seam's in-memory adapter for unit tests.
type fakeLoadSource struct {
	json    map[string][]byte // Key: table + "|" + partVal
	errs    map[string]error
	fetched time.Time
	calls   []string
}

func (f *fakeLoadSource) DatasetJSON(_ context.Context, table, _, partVal string) ([]byte, time.Time, error) {
	f.calls = append(f.calls, table+"|"+partVal)
	if err := f.errs[table+"|"+partVal]; err != nil {
		return nil, time.Time{}, err
	}
	b, ok := f.json[table+"|"+partVal]
	if !ok {
		return []byte("[]"), f.fetched, nil
	}
	return b, f.fetched, nil
}

func TestRunLoadSpecsReturnsJoinedPartitionErrorsAndContinues(t *testing.T) {
	readErr := errors.New("partition read failed")
	transformErr := errors.New("partition transform failed")
	src := &fakeLoadSource{
		json: map[string][]byte{
			"probe|B": []byte(`[{"x":2}]`),
			"probe|C": []byte(`[{"x":3}]`),
		},
		errs:    map[string]error{"probe|A": readErr},
		fetched: time.Now(),
	}
	var loaded []string
	spec := loadSpec{
		key: "probe", table: "probe", partCol: "city",
		partitions: func() []string { return []string{"A", "B", "C"} },
		load: func(_ context.Context, _ *json.Decoder, _ pipeline.CopyUpsertSink, part string) error {
			loaded = append(loaded, part)
			if part == "B" {
				return transformErr
			}
			return nil
		},
	}

	_, err := runLoadSpecs(context.Background(), src, nil, nil, []loadSpec{spec})
	if !errors.Is(err, readErr) || !errors.Is(err, transformErr) {
		t.Fatalf("runLoadSpecs error = %v, want joined read and transform errors", err)
	}
	if got, want := src.calls, []string{"probe|A", "probe|B", "probe|C"}; !slices.Equal(got, want) {
		t.Fatalf("dataset calls = %v, want %v", got, want)
	}
	if got, want := loaded, []string{"B", "C"}; !slices.Equal(got, want) {
		t.Fatalf("loaded partitions = %v, want %v", got, want)
	}
}

func TestConfiguredInvalidRawDatabaseURLFailsClosed(t *testing.T) {
	t.Setenv("RAW_DATABASE_URL", "://invalid")
	pool, cleanup, err := rawSourcePool(context.Background(), nil)
	if cleanup != nil {
		cleanup()
	}
	if err == nil {
		t.Fatalf("rawSourcePool returned pool %v and nil error for configured invalid URL", pool)
	}
}

func TestConfiguredUnreachableRawDatabaseURLFailsClosed(t *testing.T) {
	t.Setenv("RAW_DATABASE_URL", "postgres://test:test@127.0.0.1:1/test?connect_timeout=1")
	pool, cleanup, err := rawSourcePool(context.Background(), nil)
	if cleanup != nil {
		cleanup()
	}
	if err == nil {
		t.Fatalf("rawSourcePool returned pool %v and nil error for unreachable configured database", pool)
	}
}

func TestRawSourcePoolHonorsCanceledContext(t *testing.T) {
	t.Setenv("RAW_DATABASE_URL", "postgres://test:test@127.0.0.1:1/test?connect_timeout=30")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	started := time.Now()
	pool, cleanup, err := rawSourcePool(ctx, nil)
	if cleanup != nil {
		cleanup()
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("rawSourcePool returned pool %v and error %v, want context.Canceled", pool, err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("rawSourcePool took %v with an already-canceled context", elapsed)
	}
}

func TestRawSourcePoolNormalizesNilContext(t *testing.T) {
	t.Setenv("RAW_DATABASE_URL", "postgres://test:test@127.0.0.1:1/test?connect_timeout=1")
	pool, cleanup, err := rawSourcePool(nil, nil) //nolint:staticcheck // SA1012: the nil context is the input under test
	if cleanup != nil {
		cleanup()
	}
	if err == nil {
		t.Fatalf("rawSourcePool returned pool %v and nil error for unreachable configured database", pool)
	}
}

func TestStalenessCheckSkips(t *testing.T) {
	// A partition older than the 27h threshold must be skipped, not loaded.
	if !raw.IsStale(time.Now().Add(-28 * time.Hour)) {
		t.Fatal("28h old partition should be stale")
	}
	if raw.IsStale(time.Now().Add(-1 * time.Hour)) {
		t.Fatal("1h old partition should be fresh")
	}
}

func TestBusLoaderOrdersInterCityLastAndExcludesLienchiang(t *testing.T) {
	got := dataset.BusLoadCities()
	if len(got) == 0 || got[len(got)-1] != "InterCity" {
		t.Fatalf("busLoadCities = %v, want InterCity last", got)
	}
	if slices.Contains(got, "LienchiangCounty") {
		t.Fatalf("busLoadCities = %v, must exclude unsupported Lienchiang", got)
	}
	// Landing still covers both partitions; this ordering is load-only.
	landed := dataset.AllCities()
	if !slices.Contains(landed, "InterCity") || !slices.Contains(landed, "LienchiangCounty") {
		t.Fatalf("allCities = %v, ingest order/coverage was changed", landed)
	}
	for _, spec := range loaderRegistry(&fakeLoadSource{}) {
		if spec.key != "bus" {
			continue
		}
		parts := spec.partitions()
		if !slices.Equal(parts, got) {
			t.Fatalf("%s loader partitions = %v, want %v", spec.key, parts, got)
		}
	}
}

// railDateWindow feeds both the ingestor's landing partitions and the loader's
// read partitions; an off-by-one here silently drops the first or last landed
// timetable date from every load.
func TestRailDateWindow(t *testing.T) {
	// Sample today before and after the call so the assertion cannot flake if
	// the test straddles midnight.
	before := time.Now().Format(time.DateOnly)
	got := dataset.RailDateWindow(2)
	after := time.Now().Format(time.DateOnly)
	if len(got) != 3 {
		t.Fatalf("dataset.RailDateWindow(2) returned %d entries, want 3", len(got))
	}
	if got[0] != before && got[0] != after {
		t.Fatalf("dataset.RailDateWindow(2)[0] = %s, want today (%s or %s)", got[0], before, after)
	}
	first, err := time.Parse(time.DateOnly, got[0])
	if err != nil {
		t.Fatal(err)
	}
	for i, d := range got {
		if want := first.AddDate(0, 0, i).Format(time.DateOnly); d != want {
			t.Fatalf("dataset.RailDateWindow(2)[%d] = %s, want %s", i, d, want)
		}
	}
	if single := dataset.RailDateWindow(0); len(single) != 1 {
		t.Fatalf("dataset.RailDateWindow(0) = %v, want exactly one entry", single)
	}
}

func TestRunLoadIteratesPartitionsAndDecodes(t *testing.T) {
	// A registry spec with two partitions must invoke datasetJSON once per
	// partition and hand each a decoder positioned at the array.
	src := &fakeLoadSource{
		json: map[string][]byte{
			"probe|A": []byte(`[{"x":1}]`),
			"probe|B": []byte(`[{"x":2},{"x":3}]`),
		},
		fetched: time.Now(),
	}
	var seen []int
	spec := loadSpec{
		key: "probe", table: "probe", partCol: "city",
		partitions: func() []string { return []string{"A", "B"} },
		load: func(_ context.Context, dec *json.Decoder, _ pipeline.CopyUpsertSink, _ string) error {
			if _, err := dec.Token(); err != nil { // opening '['
				return err
			}
			for dec.More() {
				var m struct {
					X int `json:"x"`
				}
				if err := dec.Decode(&m); err != nil {
					return err
				}
				seen = append(seen, m.X)
			}
			return nil
		},
	}
	if _, err := runLoadSpecs(context.Background(), src, nil, nil, []loadSpec{spec}); err != nil {
		t.Fatalf("runLoadSpecs: %v", err)
	}
	if len(seen) != 3 || seen[0] != 1 || seen[1] != 2 || seen[2] != 3 {
		t.Fatalf("decoded values = %v, want [1 2 3]", seen)
	}
	if len(src.calls) != 2 || src.calls[0] != "probe|A" || src.calls[1] != "probe|B" {
		t.Fatalf("datasetJSON calls = %v", src.calls)
	}
}

func TestRunLoadSkipsStalePartition(t *testing.T) {
	src := &fakeLoadSource{
		json:    map[string][]byte{"probe|A": []byte(`[{"x":1}]`)},
		fetched: time.Now().Add(-40 * time.Hour), // stale
	}
	loaded := false
	spec := loadSpec{
		key: "probe", table: "probe", partCol: "city",
		partitions: func() []string { return []string{"A"} },
		load: func(_ context.Context, _ *json.Decoder, _ pipeline.CopyUpsertSink, _ string) error {
			loaded = true
			return nil
		},
	}
	stats, err := runLoadSpecs(context.Background(), src, nil, nil, []loadSpec{spec})
	if !errors.Is(err, errLoadStale) {
		t.Fatalf("runLoadSpecs error = %v, want errLoadStale", err)
	}
	if stats.failed != 1 || stats.ok != 0 {
		t.Fatalf("stats = %+v, want a landed-but-stale partition counted as failed", stats)
	}
	if loaded {
		t.Fatal("stale partition must be skipped, load ran anyway")
	}
}

func TestRunLoadStaleOKLoadsOldButSkipsEmpty(t *testing.T) {
	run := func(name string, fetched time.Time, hasRows bool) bool {
		body := map[string][]byte{}
		if hasRows {
			body["probe|A"] = []byte(`[{"x":1}]`)
		}
		src := &fakeLoadSource{json: body, fetched: fetched}
		loaded := false
		spec := loadSpec{
			key: "probe", table: "probe", partCol: "system", staleOK: true,
			partitions: func() []string { return []string{"A"} },
			load: func(_ context.Context, _ *json.Decoder, _ pipeline.CopyUpsertSink, _ string) error {
				loaded = true
				return nil
			},
		}
		stats, err := runLoadSpecs(context.Background(), src, nil, nil, []loadSpec{spec})
		if hasRows && err != nil {
			t.Fatalf("%s: runLoadSpecs: %v", name, err)
		}
		// A zero fetched_at means the partition never landed, which is not a
		// run failure: the rail date windows outrun TDX's publication horizon
		// every day. It must still be skipped, just not reported as stale.
		if !hasRows {
			if err != nil {
				t.Fatalf("%s: runLoadSpecs error = %v, want a never-landed partition to be skipped silently", name, err)
			}
			if stats.skipped != 1 || stats.failed != 0 {
				t.Fatalf("%s: stats = %+v, want the partition counted as skipped", name, stats)
			}
		}
		return loaded
	}
	// staleOK: a landing far past staleAfter must still load (304-served static data).
	if !run("old", time.Now().Add(-200*time.Hour), true) {
		t.Fatal("staleOK partition with old-but-present landing must load")
	}
	// staleOK still honors the empty guard: a zero fetched_at (empty partition,
	// i.e. a landing that never happened) must not DELETE-and-reinsert nothing.
	if run("empty", time.Time{}, false) {
		t.Fatal("staleOK partition with empty landing must be skipped")
	}
}

func TestLoaderRegistryKeysUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, s := range loaderRegistry(nil) {
		if seen[s.key] {
			t.Fatalf("duplicate registry key %q", s.key)
		}
		seen[s.key] = true
	}
}

func TestLoaderExceptionalBindingsUseSemanticSink(t *testing.T) {
	tests := []struct {
		key       string
		operation string
		part      string
	}{
		{key: "bus", operation: "bus city assembly", part: "Taipei"},
		{key: "bus_dailytimetable", operation: "bus daily timetable", part: "Taipei"},
		{key: "mrt_odfare", operation: "MRT journey matrix", part: "TRTC"},
		{key: "mrt_traveltime", operation: "MRT travel time", part: "TRTC"},
		{key: "thsr_station", operation: "THSR stations", part: ""},
	}
	bindings := loaderTransforms(&fakeLoadSource{})
	for _, tt := range tests {
		t.Run(tt.key, func(t *testing.T) {
			sink := &fakeLoadSink{}
			dec := json.NewDecoder(bytes.NewReader([]byte("[]")))
			if err := bindings[tt.key].loadFull(context.Background(), dec, sink, tt.part); err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(sink.semanticCalls) != 1 {
				t.Fatalf("semantic calls = %v, want one %q call", sink.semanticCalls, tt.operation)
			}
			got := sink.semanticCalls[0]
			if got.operation != tt.operation || got.part != tt.part {
				t.Fatalf("semantic call = %+v, want operation %q part %q", got, tt.operation, tt.part)
			}
		})
	}
}

func TestLoadBusDailyTimetableWritesRedis(t *testing.T) {
	rc := dialTestRedis(t)
	defer func() { _ = rc.Close() }()

	const uid = "KHH_DTT_SUB1"
	key := "bus_daily_timetable:" + uid
	_ = rc.Del(context.Background(), key).Err()
	defer func() { _ = rc.Del(context.Background(), key).Err() }()

	body := []byte(`[{"SubRouteUID":"` + uid + `","Direction":0,"Timetables":[{"TripID":"T1","IsLowFloor":true,"StopTimes":[{"StopSequence":1,"StopUID":"S1","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]}]`)
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := bus.LoadDailyTimetable(context.Background(), dec, nil, nil, rc, "Kaohsiung"); err != nil {
		t.Fatalf("loadBusDailyTimetable: %v", err)
	}

	pb, err := rc.Get(context.Background(), key).Bytes()
	if err != nil {
		t.Fatalf("read %s: %v", key, err)
	}
	var got models.Bus_DailyTimetables
	if err := proto.Unmarshal(pb, &got); err != nil {
		t.Fatalf("unmarshal proto: %v", err)
	}
	if got.SubRouteUID != uid {
		t.Fatalf("SubRouteUID = %q, want %q", got.SubRouteUID, uid)
	}
	dir0, ok := got.Direction[0]
	if !ok || len(dir0.DailyTimetables) != 1 {
		t.Fatalf("direction 0 timetables = %+v, want one entry", got.Direction)
	}
	if dir0.DailyTimetables[0].TripID != "T1" || len(dir0.DailyTimetables[0].StopTimes) != 1 {
		t.Fatalf("assembled trip = %+v, want TripID T1 with one stop", dir0.DailyTimetables[0])
	}
	ttl := rc.TTL(context.Background(), key).Val()
	if ttl <= 25*time.Hour+59*time.Minute || ttl > 26*time.Hour {
		t.Fatalf("TTL = %s, want 26h", ttl)
	}
}

type fixtureSource struct {
	dir     string
	fetched time.Time
}

func (f fixtureSource) DatasetJSON(_ context.Context, table, _, _ string) ([]byte, time.Time, error) {
	b, err := os.ReadFile(filepath.Join(f.dir, table+".json"))
	if err != nil {
		// Absent fixture → empty array, treated as fresh so the transform runs on
		// zero rows rather than being staleness-skipped.
		return []byte("[]"), f.fetched, nil //nolint:nilerr // a missing fixture is the empty-dataset case, not a failure
	}
	return b, f.fetched, nil
}

func provisionThsrStationSink(t *testing.T, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	ddl := []string{
		`CREATE TABLE IF NOT EXISTS thsr_stations (
			station_id text PRIMARY KEY,
			name text,
			city text,
			geom geometry(Point,4326),
			stationcode text,
			updated_at timestamptz NOT NULL DEFAULT NOW())`,
	}
	for _, s := range ddl {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("provision thsr_stations sink: %v\nDDL: %s", err, s)
		}
	}
}

func TestLoaderReplayThsrStation(t *testing.T) {
	pool := loaderTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	provisionThsrStationSink(t, ctx, pool)
	cleanup := func() {
		_, _ = pool.Exec(ctx, "DELETE FROM thsr_stations WHERE station_id IN ('0990','1000')")
	}
	cleanup()
	defer cleanup()

	src := fixtureSource{dir: "testdata/raw_tdx", fetched: time.Now()}
	if _, err := runLoad(ctx, src, pool, nil, []string{"thsr_station"}); err != nil {
		t.Fatalf("runLoad: %v", err)
	}

	var n int
	if err := pool.QueryRow(ctx,
		"SELECT count(*) FROM thsr_stations WHERE station_id IN ('0990','1000')").Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 2 {
		t.Fatalf("loaded %d thsr stations, want 2", n)
	}

	// The reconstructed geom must round-trip the fixture position through the
	// transform's POINT(lon lat) formatting, proving the fixture keys decoded into
	// the railStation struct (not merely that rows appeared).
	var geom string
	if err := pool.QueryRow(ctx,
		"SELECT ST_AsText(geom) FROM thsr_stations WHERE station_id='0990'").Scan(&geom); err != nil {
		t.Fatalf("read geom: %v", err)
	}
	if geom != "POINT(121.6067 25.0533)" {
		t.Fatalf("geom = %q, want POINT(121.6067 25.0533)", geom)
	}
}

func TestMarkerEarned(t *testing.T) {
	cases := []struct {
		name  string
		stats loadStats
		err   error
		want  bool
	}{
		// The regression this whole change exists for: one city rejecting a
		// bad row must not strand changetovector and the segment-time passes.
		{"partial load publishes", loadStats{ok: 19, failed: 1}, errors.New("bus Taoyuan: Shape[107] references unknown"), true},
		{"clean load publishes", loadStats{ok: 20}, nil, true},
		{"rail horizon skips do not block", loadStats{ok: 20, skipped: 20}, nil, true},
		{"nothing loaded withholds", loadStats{failed: 20}, errors.New("boom"), false},
		{"empty run withholds", loadStats{}, nil, false},
		// A truncated run is unfinished, not partial: the partitions it never
		// reached would look current to a downstream stage.
		{"deadline withholds despite progress", loadStats{ok: 12}, fmt.Errorf("load: %w", context.DeadlineExceeded), false},
		{"cancel withholds despite progress", loadStats{ok: 12}, fmt.Errorf("load: %w", context.Canceled), false},
	}
	for _, c := range cases {
		if got := markerEarned(c.stats, c.err); got != c.want {
			t.Errorf("%s: markerEarned(%+v, %v) = %v, want %v", c.name, c.stats, c.err, got, c.want)
		}
	}
}
