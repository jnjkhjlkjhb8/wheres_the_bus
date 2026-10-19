package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/mrt"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/rail"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

// copyUpsertCall records one captured copyUpsert invocation so a test can assert
// on the target temp table, columns, and staged rows without a database.
type copyUpsertCall struct {
	spec pipeline.CopyUpsertSpec
	rows [][]any
}

// fakeLoadSink is the loadSink seam's in-memory adapter: it captures copyUpsert
// and semantic calls so transforms run end to end without PostgreSQL or Redis.
type fakeLoadSink struct {
	calls         []copyUpsertCall
	semanticCalls []semanticLoadCall
}

type semanticLoadCall struct {
	operation string
	part      string
}

func (f *fakeLoadSink) CopyUpsert(_ context.Context, spec pipeline.CopyUpsertSpec, rows [][]any) error {
	f.calls = append(f.calls, copyUpsertCall{spec: spec, rows: rows})
	return nil
}

func (f *fakeLoadSink) recordSemantic(operation, part string) error {
	f.semanticCalls = append(f.semanticCalls, semanticLoadCall{operation: operation, part: part})
	return nil
}

func (f *fakeLoadSink) loadBusCity(_ context.Context, _ pipeline.LoadSource, part string) error {
	return f.recordSemantic("bus city assembly", part)
}

func (f *fakeLoadSink) loadBusDailyTimetable(_ context.Context, _ *json.Decoder, _ pipeline.LoadSource, part string) error {
	return f.recordSemantic("bus daily timetable", part)
}

func (f *fakeLoadSink) loadMrtJourneyMatrix(_ context.Context, _ *json.Decoder, part string) error {
	return f.recordSemantic("MRT journey matrix", part)
}

func (f *fakeLoadSink) loadMrtTravelTime(_ context.Context, _ pipeline.LoadSource, part string) error {
	return f.recordSemantic("MRT travel time", part)
}

func (f *fakeLoadSink) loadThsrStations(_ context.Context, _ *json.Decoder, part string) error {
	return f.recordSemantic("THSR stations", part)
}

// decodeInto returns a decoder positioned at the start of a committed JSON array.
func decodeInto(body string) *json.Decoder {
	return json.NewDecoder(bytes.NewReader([]byte(body)))
}

func TestLoadMrtStationsThroughSink(t *testing.T) {
	body := `[{"StationID":"BL12","StationName":{"Zh_tw":"南港展覽館"},"LocationCity":"Taipei","StationPosition":{"PositionLon":121.6,"PositionLat":25.05},"BikeAllowOnHoliday":true}]`
	sink := &fakeLoadSink{}
	if err := mrt.LoadStations(context.Background(), decodeInto(body), sink, "TRTC"); err != nil {
		t.Fatalf("mrt.LoadStations: %v", err)
	}
	if len(sink.calls) != 1 {
		t.Fatalf("copyUpsert calls = %d, want 1", len(sink.calls))
	}
	c := sink.calls[0]
	if c.spec.Key != "mrt_station" || c.spec.TempTable != "temp_mrt" {
		t.Fatalf("spec key/temp = %q/%q", c.spec.Key, c.spec.TempTable)
	}
	wantCols := []string{"geom", "system", "name", "city", "id", "bike"}
	if !equalStrings(c.spec.CopyCols, wantCols) {
		t.Fatalf("copyCols = %v, want %v", c.spec.CopyCols, wantCols)
	}
	if len(c.rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(c.rows))
	}
	want := []any{"POINT(121.600000 25.050000)", "TRTC", "南港展覽館", "Taipei", "BL12", true}
	for i, v := range want {
		if c.rows[0][i] != v {
			t.Fatalf("row[%d] = %#v, want %#v", i, c.rows[0][i], v)
		}
	}
}

func TestLoadTraTimetableThroughSink(t *testing.T) {
	// WheelchairFlag (bit 0) + DiningFlag (bit 2) + the train-wide
	// SuspendedFlag (bit 7) set => railMask = 1|4|128 = 133. A suspended train
	// marks every staged stop suspended even when the stop-level flag is zero.
	body := `[{"DailyTrainInfo":{"TrainNo":"123","Direction":0,"StartingStationID":"1000","EndingStationID":"1001","WheelchairFlag":1,"PackageServiceFlag":0,"DiningFlag":1,"BikeFlag":0,"BreastFeedingFlag":0,"DailyFlag":0,"ServiceAddedFlag":0,"SuspendedFlag":1},"StopTimes":[{"StopSequence":1,"StationID":"1000","StationName":{"Zh_tw":"台北"},"ArrivalTime":"08:00","DepartureTime":"08:01","SuspendedFlag":0}]}]`
	sink := &fakeLoadSink{}
	if err := rail.LoadTraTimetable(context.Background(), decodeInto(body), sink, "2026-07-04"); err != nil {
		t.Fatalf("rail.LoadTraTimetable: %v", err)
	}
	if len(sink.calls) != 1 {
		t.Fatalf("copyUpsert calls = %d, want 1", len(sink.calls))
	}
	c := sink.calls[0]
	if c.spec.Key != "tra_timetable" || c.spec.TempTable != "temp_tra_timetable" {
		t.Fatalf("spec key/temp = %q/%q", c.spec.Key, c.spec.TempTable)
	}
	if len(c.rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(c.rows))
	}
	// mask is column index 16 in the temp_tra_timetable row layout.
	if got, ok := c.rows[0][16].(uint16); !ok || got != 133 {
		t.Fatalf("mask = %#v, want uint16(133)", c.rows[0][16])
	}
	if c.rows[0][0] != "2026-07-04" || c.rows[0][12] != "1000" {
		t.Fatalf("row train_date/stationid = %v/%v", c.rows[0][0], c.rows[0][12])
	}
}

func TestLoadThsrTimetableThroughSink(t *testing.T) {
	// Overnight handling stays in the THSR row mapping; assert it survives to the
	// staged row (column index 13 in the temp_thsr_timetable layout).
	body := `[{"TrainDate":"2026-07-04","DailyTrainInfo":{"TrainNo":"0101","Direction":1,"StartingStationID":"0990","EndingStationID":"1070","Overnight":true},"StopTimes":[{"StopSequence":1,"StationID":"0990","StationName":{"Zh_tw":"南港"},"ArrivalTime":"23:50","DepartureTime":"23:51"}]}]`
	sink := &fakeLoadSink{}
	if err := rail.LoadThsrTimetable(context.Background(), decodeInto(body), sink, "2026-07-04"); err != nil {
		t.Fatalf("rail.LoadThsrTimetable: %v", err)
	}
	if len(sink.calls) != 1 {
		t.Fatalf("copyUpsert calls = %d, want 1", len(sink.calls))
	}
	c := sink.calls[0]
	if c.spec.Key != "thsr_timetable" || c.spec.TempTable != "temp_thsr_timetable" {
		t.Fatalf("spec key/temp = %q/%q", c.spec.Key, c.spec.TempTable)
	}
	if len(c.rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(c.rows))
	}
	if got, ok := c.rows[0][13].(bool); !ok || !got {
		t.Fatalf("overnight = %#v, want true", c.rows[0][13])
	}
}

// TestLoadMrtStationsEmptyNoCall proves an empty payload short-circuits before
// touching the sink (no partition write on zero rows), matching the transform's
// len==0 guard.
func TestLoadMrtStationsEmptyNoCall(t *testing.T) {
	sink := &fakeLoadSink{}
	if err := mrt.LoadStations(context.Background(), decodeInto(`[]`), sink, "TRTC"); err != nil {
		t.Fatalf("mrt.LoadStations: %v", err)
	}
	if len(sink.calls) != 0 {
		t.Fatalf("copyUpsert calls = %d, want 0 for empty payload", len(sink.calls))
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestCopyUpsertPostgresLateFailureRollsBackAndEmptyReplaceCommits(t *testing.T) {
	dsn := os.Getenv("TASK5_DATABASE_URL")
	if dsn == "" {
		t.Skip("TASK5_DATABASE_URL not set; skipping PostgreSQL rollback integration")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect PostgreSQL: %v", err)
	}
	defer pool.Close()
	const target = "task5_copy_upsert_target"
	if _, err := pool.Exec(ctx, `DROP TABLE IF EXISTS `+target); err != nil {
		t.Fatalf("drop target: %v", err)
	}
	defer func() { _, _ = pool.Exec(ctx, `DROP TABLE IF EXISTS `+target) }()
	if _, err := pool.Exec(ctx, `CREATE TABLE `+target+` (id int PRIMARY KEY, marker text NOT NULL)`); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO `+target+` VALUES (1, 'old')`); err != nil {
		t.Fatalf("seed target: %v", err)
	}

	spec := pipeline.CopyUpsertSpec{
		Key:       "pg_probe",
		PreExec:   []pipeline.CopyUpsertStmt{{SQL: `DELETE FROM ` + target}},
		CreateSQL: `CREATE TEMP TABLE temp_task5_probe (id int, marker text) ON COMMIT DROP`,
		TempTable: "temp_task5_probe",
		CopyCols:  []string{"id", "marker"},
		InsertSQL: `INSERT INTO ` + target + ` SELECT id, marker FROM temp_task5_probe`,
	}
	sink := pgLoadSink{db: pool}
	err = sink.CopyUpsert(ctx, spec, [][]any{{2, "new-a"}, {2, "new-b"}})
	if err == nil || !errMentions(err, "final exec") {
		t.Fatalf("copyUpsert error = %v, want wrapped late INSERT failure", err)
	}
	var oldCount, newCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE id=1 AND marker='old'), count(*) FILTER (WHERE id=2) FROM `+target).Scan(&oldCount, &newCount); err != nil {
		t.Fatalf("read rollback target: %v", err)
	}
	if oldCount != 1 || newCount != 0 {
		t.Fatalf("after rollback old=%d new=%d, want old=1 new=0", oldCount, newCount)
	}

	if err := sink.CopyUpsert(ctx, spec, nil); err != nil {
		t.Fatalf("empty partition replacement: %v", err)
	}
	var remaining int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+target).Scan(&remaining); err != nil {
		t.Fatalf("count empty replacement: %v", err)
	}
	if remaining != 0 {
		t.Fatalf("empty replacement left %d rows, want 0", remaining)
	}
}

func TestCopyUpsertPostgresCommitFailureReturnsPrimaryErrorOnly(t *testing.T) {
	dsn := os.Getenv("TASK5_DATABASE_URL")
	if dsn == "" {
		t.Skip("TASK5_DATABASE_URL not set; skipping PostgreSQL commit-error integration")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect PostgreSQL: %v", err)
	}
	defer pool.Close()
	const target = "task5_copy_upsert_commit_target"
	if _, err := pool.Exec(ctx, `DROP TABLE IF EXISTS `+target); err != nil {
		t.Fatalf("drop target: %v", err)
	}
	defer func() { _, _ = pool.Exec(ctx, `DROP TABLE IF EXISTS `+target) }()
	if _, err := pool.Exec(ctx, `CREATE TABLE `+target+` (
		id int,
		CONSTRAINT task5_copy_upsert_commit_unique UNIQUE (id) DEFERRABLE INITIALLY DEFERRED
	)`); err != nil {
		t.Fatalf("create target: %v", err)
	}

	spec := pipeline.CopyUpsertSpec{
		Key:       "pg_commit_probe",
		CreateSQL: `CREATE TEMP TABLE temp_task5_commit_probe (id int) ON COMMIT DROP`,
		TempTable: "temp_task5_commit_probe",
		CopyCols:  []string{"id"},
		InsertSQL: `INSERT INTO ` + target + ` SELECT id FROM temp_task5_commit_probe`,
	}
	err = (pgLoadSink{db: pool}).CopyUpsert(ctx, spec, [][]any{{1}, {1}})
	if err == nil || !errMentions(err, "commit") {
		t.Fatalf("copyUpsert error = %v, want wrapped commit-time constraint failure", err)
	}
	if errMentions(err, "rollback") {
		t.Fatalf("copyUpsert error = %v, pgx closed-transaction rollback must be ignored", err)
	}
	var rows int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+target).Scan(&rows); err != nil {
		t.Fatalf("count target after failed commit: %v", err)
	}
	if rows != 0 {
		t.Fatalf("failed commit left %d rows, want 0", rows)
	}
}
