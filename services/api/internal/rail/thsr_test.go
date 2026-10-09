package rail

import (
	"context"
	"errors"
	"regexp"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/pashagolub/pgxmock/v4"
	"google.golang.org/protobuf/proto"
)

func TestQueryThsrFaresReadsFare(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT ticket_type, fare_class, cabin_class, price FROM thsr_fares").
		WithArgs("0990", "1000").
		WillReturnRows(pgxmock.NewRows([]string{"ticket_type", "fare_class", "cabin_class", "price"}).AddRow(uint8(1), uint8(2), uint8(3), int32(120)))

	fares, err := QueryTHSRFares(context.Background(), db, "0990", "1000")
	if err != nil {
		t.Fatal(err)
	}
	if len(fares) != 1 || fares[0].Price != 120 {
		t.Fatalf("fares = %+v, want one fare priced 120", fares)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestQueryThsrFaresKeepsEveryClass(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	wantQuery := `SELECT ticket_type, fare_class, cabin_class, price FROM thsr_fares WHERE origin_station_id = $1 AND destination_station_id = $2 AND ticket_type = 1 AND price > 0 ORDER BY cabin_class, fare_class, price;`
	db.ExpectQuery(regexp.QuoteMeta(wantQuery)).
		WithArgs("0990", "1070").
		WillReturnRows(pgxmock.NewRows([]string{"ticket_type", "fare_class", "cabin_class", "price"}).
			AddRow(uint8(1), uint8(1), uint8(1), int32(1530)).
			AddRow(uint8(1), uint8(9), uint8(1), int32(765)).
			AddRow(uint8(1), uint8(1), uint8(2), int32(2000)).
			AddRow(uint8(1), uint8(1), uint8(3), int32(1480)))

	fares, err := QueryTHSRFares(context.Background(), db, "0990", "1070")
	if err != nil {
		t.Fatal(err)
	}
	if len(fares) != 4 {
		t.Fatalf("fares = %+v, want every fare class and cabin class", fares)
	}
	var halfStandard *models.ThsaFare
	for _, fare := range fares {
		if fare.FareClass == 9 && fare.CabinClas == 1 {
			halfStandard = fare
		}
	}
	if halfStandard == nil || halfStandard.Price != 765 {
		t.Fatalf("fares = %+v, want the 半票標準 row at 765", fares)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestQueryThsrFaresEmptyOnEmptyDB(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT ticket_type, fare_class, cabin_class, price FROM thsr_fares").
		WithArgs("0990", "1000").
		WillReturnRows(pgxmock.NewRows([]string{"ticket_type", "fare_class", "cabin_class", "price"}))

	fares, err := QueryTHSRFares(context.Background(), db, "0990", "1000")
	if err != nil {
		t.Fatal(err)
	}
	if len(fares) != 0 {
		t.Fatalf("want empty, got %+v", fares)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestThsrTimetablePayloadUsesOriginDeparture(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	cols := []string{
		"trainno", "starting_station_id", "starting_station_name",
		"ending_station_id", "ending_station_name", "arrivaltime",
		"departuretime", "note", "overnight", "stationid", "stopsequence",
	}
	db.ExpectQuery("FROM thsr_timetable WHERE stationid").
		WithArgs([]string{"0990", "1070"}, "2026-07-10").
		WillReturnRows(pgxmock.NewRows(cols).
			// Southbound 0801: origin 南港 (seq 1, terminus → no arrival, departs 06:30),
			// dest 左營 (seq 12, arrives 08:00) — the leg we want.
			AddRow("0801", "0990", "南港", "1070", "左營", "00:00:00", "06:30:00", "", false, "0990", 1).
			AddRow("0801", "0990", "南港", "1070", "左營", "08:00:00", "08:02:00", "", false, "1070", 12).
			// Northbound 0802 also calls at both stations but in reverse order
			// (左營 seq 1 → 南港 seq 12); it must be dropped, not paired backwards.
			AddRow("0802", "1070", "左營", "0990", "南港", "00:00:00", "09:00:00", "", false, "1070", 1).
			AddRow("0802", "1070", "左營", "0990", "南港", "10:30:00", "10:32:00", "", false, "0990", 12))

	date := time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC)
	payload, n, err := THSRTimetablePayload(context.Background(), db, "0990", "1070", date)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("paired legs = %d, want 1", n)
	}
	var tt models.ThsrTimetables
	if err := proto.Unmarshal(payload, &tt); err != nil {
		t.Fatal(err)
	}
	if len(tt.Items) != 1 {
		t.Fatalf("items = %+v, want one", tt.Items)
	}
	got := tt.Items[0]
	if got.Starting_Time != "06:30:00" {
		t.Errorf("Starting_Time = %q, want origin departure 06:30:00", got.Starting_Time)
	}
	if got.Ending_Time != "08:00:00" {
		t.Errorf("Ending_Time = %q, want dest arrival 08:00:00", got.Ending_Time)
	}
	if got.Travel_Time != "1h30m0s" {
		t.Errorf("Travel_Time = %q, want 1h30m0s", got.Travel_Time)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestThsrTimetablePayloadDurationDependsOnClockOrderNotOvernightFlag(t *testing.T) {
	tests := []struct {
		name         string
		departure    string
		arrival      string
		overnight    bool
		wantDuration string
	}{
		{name: "positive duration flag false", departure: "06:30:00", arrival: "08:00:00", overnight: false, wantDuration: "1h30m0s"},
		{name: "positive duration flag true", departure: "06:30:00", arrival: "08:00:00", overnight: true, wantDuration: "1h30m0s"},
		{name: "negative duration flag false", departure: "23:50:00", arrival: "00:10:00", overnight: false, wantDuration: "20m0s"},
		{name: "negative duration flag true", departure: "23:50:00", arrival: "00:10:00", overnight: true, wantDuration: "20m0s"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()

			cols := []string{
				"trainno", "starting_station_id", "starting_station_name",
				"ending_station_id", "ending_station_name", "arrivaltime",
				"departuretime", "note", "overnight", "stationid", "stopsequence",
			}
			db.ExpectQuery("FROM thsr_timetable WHERE stationid").
				WithArgs([]string{"0990", "1070"}, "2026-07-10").
				WillReturnRows(pgxmock.NewRows(cols).
					AddRow("0801", "0990", "南港", "1070", "左營", tt.departure, tt.departure, "", tt.overnight, "0990", 1).
					AddRow("0801", "0990", "南港", "1070", "左營", tt.arrival, tt.arrival, "", tt.overnight, "1070", 12))

			date := time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC)
			payload, n, err := THSRTimetablePayload(context.Background(), db, "0990", "1070", date)
			if err != nil {
				t.Fatal(err)
			}
			if n != 1 {
				t.Fatalf("paired legs = %d, want 1", n)
			}
			var timetables models.ThsrTimetables
			if err := proto.Unmarshal(payload, &timetables); err != nil {
				t.Fatal(err)
			}
			got := timetables.Items[0]
			if got.Travel_Time != tt.wantDuration {
				t.Fatalf("Travel_Time = %q, want %q", got.Travel_Time, tt.wantDuration)
			}
			if got.Overnight != tt.overnight {
				t.Fatalf("Overnight = %v, want %v", got.Overnight, tt.overnight)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestThsrTimetablePayloadQueryHasDeterministicOrder(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	wantQuery := `FROM thsr_timetable WHERE stationid = ANY($1) AND train_date = $2 ORDER BY trainno, stopsequence, stationid;`
	db.ExpectQuery(regexp.QuoteMeta(wantQuery)).
		WithArgs([]string{"0990", "1070"}, "2026-07-10").
		WillReturnRows(pgxmock.NewRows([]string{"station_id"}))

	date := time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC)
	_, n, err := THSRTimetablePayload(context.Background(), db, "0990", "1070", date)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("paired legs = %d, want 0", n)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestThsrTimetablePayloadPropagatesOriginResolverErrorImmediately(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	wantErr := errors.New("THSR station lookup unavailable")
	// This is the only expected query. A destination resolver or timetable query
	// would be unexpected and prevent the sentinel from being returned unchanged.
	db.ExpectQuery("SELECT station_id FROM thsr_stations").
		WithArgs("南港").
		WillReturnError(wantErr)

	date := time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC)
	payload, n, err := THSRTimetablePayload(context.Background(), db, "南港", "左營", date)
	if err != wantErr {
		t.Fatalf("error = %v, want same sentinel %v", err, wantErr)
	}
	if payload != nil || n != 0 {
		t.Fatalf("payload = %v, leg count = %d, want nil and 0", payload, n)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestThsrStoptimesPayload(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("FROM thsr_timetable WHERE trainno").
		WithArgs("0801", "2026-07-04").
		WillReturnRows(pgxmock.NewRows([]string{"stopsequence", "stationid", "stationname", "arrivaltime", "departuretime"}).
			AddRow(1, "0990", "南港", "08:00", "08:02"))

	payload, n, err := THSRStoptimesPayload(context.Background(), db, "0801", "2026-07-04")
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("row count = %d, want 1", n)
	}
	var stops models.ThsrStoptimes
	if err := proto.Unmarshal(payload, &stops); err != nil {
		t.Fatal(err)
	}
	if len(stops.Items) != 1 || stops.Items[0].StationId != "0990" {
		t.Fatalf("stops = %+v, want one stop at 0990", stops.Items)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
