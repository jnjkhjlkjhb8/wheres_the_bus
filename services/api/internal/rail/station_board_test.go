package rail

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/pashagolub/pgxmock/v4"
)

// TestStationBoardLimitClamps pins the bounds a caller cannot cross: an
// unset limit falls back to the default rather than returning nothing, and an
// oversized one is capped rather than pulling a whole service day over the wire.
func TestStationBoardLimitClamps(t *testing.T) {
	for _, tc := range []struct {
		requested int32
		want      int
	}{
		{requested: 0, want: _stationBoardDefaultLimit},
		{requested: -5, want: _stationBoardDefaultLimit},
		{requested: 8, want: 8},
		{requested: 5000, want: _stationBoardMaxLimit},
	} {
		if got := stationBoardLimit(tc.requested); got != tc.want {
			t.Fatalf("stationBoardLimit(%d) = %d, want %d", tc.requested, got, tc.want)
		}
	}
}

// board builds a day of TRA departures at the given times.
func board(times ...string) []*models.TraStationDeparture {
	out := make([]*models.TraStationDeparture, 0, len(times))
	for _, at := range times {
		out = append(out, &models.TraStationDeparture{DepartureTime: at})
	}
	return out
}

func departureTimes(items []*models.TraStationDeparture) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		out = append(out, item.DepartureTime)
	}
	return out
}

// TestDeparturesAfterKeepsTheWindow verifies the bound is inclusive (a train
// departing exactly now is still catchable) and that an empty bound keeps the
// whole day.
func TestDeparturesAfterKeepsTheWindow(t *testing.T) {
	day := board("06:15:00", "14:32:00", "14:41:00", "23:41:00")

	got := departureTimes(departuresAfter(day, "14:32:00"))
	want := []string{"14:32:00", "14:41:00", "23:41:00"}
	if len(got) != len(want) {
		t.Fatalf("departuresAfter = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("departuresAfter = %v, want %v", got, want)
		}
	}

	if n := len(departuresAfter(day, "")); n != len(day) {
		t.Fatalf("empty bound kept %d of %d departures, want all", n, len(day))
	}
}

func TestDeparturesAfterDoesNotAliasTheDay(t *testing.T) {
	day := make([]*models.TraStationDeparture, 2, 8)
	day[0] = &models.TraStationDeparture{DepartureTime: "06:15:00"}
	day[1] = &models.TraStationDeparture{DepartureTime: "07:00:00"}

	window := departuresAfter(day, "")
	window = append(window, &models.TraStationDeparture{DepartureTime: "23:59:00"})

	if len(day) != 2 {
		t.Fatalf("day grew to %d entries", len(day))
	}
	if got := day[:cap(day)][2]; got != nil {
		t.Fatalf("append wrote %v into the cached day's spare capacity", got)
	}
	_ = window
}

// TestStationBoardWindowSkipsTopUpWhenFull pins the cheap path: a day with
// enough trains left must not cost a second query.
func TestStationBoardWindowSkipsTopUpWhenFull(t *testing.T) {
	day := board("14:32:00", "14:41:00", "14:55:00")
	called := false
	got, err := stationBoardWindow(day, "14:32:00", 2, func() ([]*models.TraStationDeparture, error) {
		called = true
		return nil, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatal("a full window must not reach for the next day")
	}
	if len(got) != 2 {
		t.Fatalf("window = %v, want 2 departures", departureTimes(got))
	}
}

// TestStationBoardWindowTopsUpNearMidnight is the reason the top-up exists: at
// 23:50 the day holds one departure, and a board of one is not an answer.
func TestStationBoardWindowTopsUpNearMidnight(t *testing.T) {
	day := board("23:41:00", "23:55:00")
	next := board("05:10:00", "06:02:00", "06:40:00")

	got, err := stationBoardWindow(day, "23:50:00", 3, func() ([]*models.TraStationDeparture, error) {
		return next, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"23:55:00", "05:10:00", "06:02:00"}
	times := departureTimes(got)
	if len(times) != len(want) {
		t.Fatalf("window = %v, want %v", times, want)
	}
	for i := range want {
		if times[i] != want[i] {
			t.Fatalf("window = %v, want %v", times, want)
		}
	}
}

// TestStationBoardWindowSurvivesTopUpFailure: the next service date is usually
// not landed yet, and that must end the board early rather than fail the
// request the rider is actually looking at.
func TestStationBoardWindowSurvivesTopUpFailure(t *testing.T) {
	day := board("23:55:00")
	got, err := stationBoardWindow(day, "", 20, func() ([]*models.TraStationDeparture, error) {
		return nil, errors.New("tomorrow is not landed")
	})
	if err == nil {
		t.Fatal("expected the top-up failure to be reported to the caller")
	}
	if len(got) != 1 {
		t.Fatalf("window = %v, want tonight's single departure", departureTimes(got))
	}
}

// TestTraStationBoardPayloadMapsRows pins the read path: the query is scoped to
// one station, date and direction, terminating services are excluded in SQL,
// and the row lands on the proto fields the app reads.
func TestTraStationBoardPayloadMapsRows(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	day := time.Date(2026, 7, 29, 0, 0, 0, 0, time.UTC)
	depart := time.Date(2026, 7, 29, 14, 32, 0, 0, time.UTC)

	// Numeric ids skip name resolution, so this is the only query expected.
	db.ExpectQuery("FROM tra_timetable WHERE stationid = \\$1").
		WithArgs("1000", "2026-07-29", int32(0)).
		WillReturnRows(pgxmock.NewRows([]string{
			"train_date", "trainno", "train_type_code", "train_type_name",
			"ending_station_name", "departuretime", "direction", "mask", "note",
		}).AddRow(day, "271", "1", "自強(3000)", "潮州", depart, int32(0), int32(128), "每日行駛"))

	items, err := TRAStationBoardPayload(context.Background(), db, "1000", day, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("items = %+v, want one departure", items)
	}
	got := items[0]
	if got.DepartureTime != "14:32:00" {
		t.Fatalf("DepartureTime = %q, want 14:32:00", got.DepartureTime)
	}
	if got.TrainDate != "2026-07-29" {
		t.Fatalf("TrainDate = %q, want 2026-07-29", got.TrainDate)
	}
	if got.Destination_Station_Name != "潮州" || got.TrainNo != "271" {
		t.Fatalf("departure = %+v, want train 271 towards 潮州", got)
	}
	// The suspended bit rides through untouched; the app decodes the mask.
	if got.Mask != 128 {
		t.Fatalf("Mask = %d, want the row's mask carried through", got.Mask)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestThsrStationBoardPayloadMapsRows is the THSR half of the read path.
func TestThsrStationBoardPayloadMapsRows(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	day := time.Date(2026, 7, 29, 0, 0, 0, 0, time.UTC)

	db.ExpectQuery("FROM thsr_timetable WHERE stationid = \\$1").
		WithArgs("1000", "2026-07-29", int32(1)).
		WillReturnRows(pgxmock.NewRows([]string{
			"train_date", "trainno", "ending_station_name", "departuretime", "direction", "note",
		}).AddRow(day, "0663", "南港", "14:36:00", int32(1), ""))

	items, err := THSRStationBoardPayload(context.Background(), db, "1000", day, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("items = %+v, want one departure", items)
	}
	if items[0].TrainNo != "0663" || items[0].DepartureTime != "14:36:00" {
		t.Fatalf("departure = %+v, want train 0663 at 14:36:00", items[0])
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
