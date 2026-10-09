package bus

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

const _specTimeTableJSON = `{
  "updateTime": 1785950118247,
  "authorityCode": "TPE",
  "specificTimeTables": {"specificTimeTable": [
    {"routeID": "10723", "subRouteID": "10723", "direction": "0",
     "timeTables": {"timeTable": [
       {"stopTimes": {"stopTime": [
          {"stopSequence": 1, "stopID": "16846", "stopName": {"zhTw": "華江站"},
           "arrivalTime": "05:35", "departureTime": "05:35"}]},
        "specialDays": {"specialDay": [
          {"dates": {"date": ["2026-08-06"]}, "serviceStatus": "1"}]}},
       {"stopTimes": {"stopTime": [
          {"stopSequence": 1, "stopID": "16846", "stopName": {"zhTw": "華江站"},
           "arrivalTime": "05:20", "departureTime": "05:20"}]},
        "specialDays": {"specialDay": [
          {"dates": {"date": ["2026-08-06"]}, "serviceStatus": "1"}]}},
       {"stopTimes": {"stopTime": [
          {"stopSequence": 1, "stopID": "16846",
           "arrivalTime": "06:00", "departureTime": "06:00"}]},
        "specialDays": {"specialDay": [
          {"dates": {"date": ["2026-08-07"]}, "serviceStatus": "1"}]}},
       {"stopTimes": {"stopTime": [
          {"stopSequence": 1, "stopID": "16846",
           "arrivalTime": "07:00", "departureTime": "07:00"}]},
        "specialDays": {"specialDay": [
          {"dates": {"date": ["2026-08-06"]}, "serviceStatus": "0"}]}}]}},
    {"routeID": "10724", "subRouteID": "10724", "direction": "null",
     "timeTables": {"timeTable": [
       {"stopTimes": {"stopTime": [
          {"stopSequence": 1, "stopID": "16847",
           "arrivalTime": "05:40", "departureTime": "05:40"}]},
        "specialDays": {"specialDay": [
          {"dates": {"date": ["2026-08-06"]}, "serviceStatus": "1"}]}}]}}]}}`

func decodeSpecTimeTable(t *testing.T) dataTaipeiSpecTimeTable {
	t.Helper()
	var feed dataTaipeiSpecTimeTable
	if err := json.Unmarshal([]byte(_specTimeTableJSON), &feed); err != nil {
		t.Fatalf("decode spec timetable: %v", err)
	}
	return feed
}

func TestDataTaipeiDailyTimetableRows(t *testing.T) {
	day := time.Date(2026, 8, 6, 11, 20, 0, 0, pipeline.Taipei)

	rows := dataTaipeiDailyTimetableRows(decodeSpecTimeTable(t), day)

	// The "null"-direction subroute is dropped whole: it names no travel
	// direction, and the loader keys on one.
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1: %+v", len(rows), rows)
	}
	row := rows[0]
	if row.SubRouteUID != "TPE10723" || row.Direction != 0 || row.BusDate != "2026-08-06" {
		t.Errorf("row = %s/%d/%s, want TPE10723/0/2026-08-06", row.SubRouteUID, row.Direction, row.BusDate)
	}
	// Only the two trips filed for this date in normal service: the 08-07 trip
	// and the 停止營運 one are both out.
	if len(row.Timetables) != 2 {
		t.Fatalf("trips = %d, want 2: %+v", len(row.Timetables), row.Timetables)
	}
	// Sorted, so an unchanged feed lands identical bytes.
	if row.Timetables[0].TripID != "2026-08-06-0520" || row.Timetables[1].TripID != "2026-08-06-0535" {
		t.Errorf("trip ids = %q, %q; want 2026-08-06-0520, 2026-08-06-0535",
			row.Timetables[0].TripID, row.Timetables[1].TripID)
	}
	stop := row.Timetables[0].StopTimes[0]
	if stop.StopUID != "TPE16846" || stop.StopSequence != 1 || stop.DepartureTime != "05:20" {
		t.Errorf("stop time = %+v, want TPE16846/1/05:20", stop)
	}
}

func TestDataTaipeiDailyTimetableRowsOtherDay(t *testing.T) {
	day := time.Date(2026, 8, 9, 0, 0, 0, 0, pipeline.Taipei)
	if rows := dataTaipeiDailyTimetableRows(decodeSpecTimeTable(t), day); len(rows) != 0 {
		t.Fatalf("rows = %d for a day nothing is filed for, want 0", len(rows))
	}
}

// The reshaped rows must survive the loader's own validation, or the landing
// would take the whole city down at load time instead of here.
func TestDataTaipeiDailyTimetableRowsPassLoaderValidation(t *testing.T) {
	day := time.Date(2026, 8, 6, 0, 0, 0, 0, pipeline.Taipei)
	rows := dataTaipeiDailyTimetableRows(decodeSpecTimeTable(t), day)

	encoded, err := json.Marshal(rows)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	var decoded []busmodel.RawDailyTimetable
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("decode as the loader does: %v", err)
	}
	if len(decoded) != len(rows) {
		t.Fatalf("decoded %d rows, want %d", len(decoded), len(rows))
	}
	for _, row := range decoded {
		if err := validateBusDailyTimetable(row); err != nil {
			t.Errorf("validateBusDailyTimetable(%s): %v", row.SubRouteUID, err)
		}
	}
}

func TestBusDailyTimetableLoadSkip(t *testing.T) {
	// Taipei is landed from Data.taipei, so it loads even though TDX serves it
	// nothing; the other four stay skipped on both sides.
	if DailyTimetableLoadSkip("Taipei") {
		t.Errorf("Taipei is skipped at load time, but its partition is landed")
	}
	if !dataset.BusDailyTimetableSkip("Taipei") {
		t.Errorf("Taipei is landed from TDX, but TDX serves it no daily timetable")
	}
	for _, city := range []string{"NewTaipei", "Tainan", "KinmenCounty", "LienchiangCounty"} {
		if !DailyTimetableLoadSkip(city) {
			t.Errorf("%s loads a partition nothing lands", city)
		}
	}
	if DailyTimetableLoadSkip("Taichung") {
		t.Errorf("Taichung is skipped, but TDX serves its daily timetable")
	}
}
