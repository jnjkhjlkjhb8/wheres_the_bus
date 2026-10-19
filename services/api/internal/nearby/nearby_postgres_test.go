package nearby

import (
	"context"
	"errors"
	"testing"

	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestPostgresNearbyStoreBusReturnsGroupUID(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("FROM bus_station_groups g WHERE ST_DWithin").
		WithArgs(121.5, 25.0, 500, 80).
		WillReturnRows(pgxmock.NewRows([]string{"id", "name", "city", "geodesic_meters", "lon", "lat"}).
			AddRow("G-1", "Taipei Main", "Taipei", 42.0, 121.51, 25.01))

	rows, err := NewPostgresNearbyStore(db).Find(context.Background(), NearbyBus, NearbyQuery{
		Origin: GeoPoint{Lon: 121.5, Lat: 25}, RadiusMeters: 500, Limit: 80,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != "G-1" || rows[0].Mode != NearbyBus {
		t.Fatalf("rows = %+v, want bus group G-1", rows)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresNearbyStorePointModes(t *testing.T) {
	tests := []struct {
		mode  NearbyMode
		table string
	}{
		{_nearbyBike, "bike_stations"},
		{_nearbyMRT, "mrt_station"},
		{_nearbyTRA, "tra_stations"},
		{_nearbyTHSR, "thsr_stations"},
	}
	for _, tt := range tests {
		t.Run(tt.table, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			db.ExpectQuery("FROM "+tt.table+" WHERE ST_DWithin").
				WithArgs(121.5, 25.0, 500, 80).
				WillReturnRows(pgxmock.NewRows([]string{"id", "name", "city", "geodesic_meters", "lon", "lat"}).
					AddRow("S-1", "Station", "Taipei", 42.0, 121.51, 25.01)).RowsWillBeClosed()
			rows, err := NewPostgresNearbyStore(db).Find(t.Context(), tt.mode, NearbyQuery{
				Origin: GeoPoint{Lon: 121.5, Lat: 25}, RadiusMeters: 500, Limit: 80,
			})
			if err != nil {
				t.Fatal(err)
			}
			want := NearbyCandidate{Mode: tt.mode, ID: "S-1", Name: "Station", City: "Taipei",
				Point: GeoPoint{Lon: 121.51, Lat: 25.01}, GeodesicMeters: 42}
			if len(rows) != 1 || rows[0] != want {
				t.Fatalf("rows = %+v, want %+v", rows, want)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPostgresNearbyStoreRejectsUnknownMode(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := NewPostgresNearbyStore(db).Find(t.Context(), NearbyMode(999), NearbyQuery{}); err == nil {
		t.Fatal("unknown transit mode queried a table")
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresNearbyStoreQueryFailure(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	want := errors.New("database unavailable")
	db.ExpectQuery("FROM bike_stations").WithArgs(0.0, 0.0, 0, 0).WillReturnError(want)
	if _, err := NewPostgresNearbyStore(db).Find(t.Context(), _nearbyBike, NearbyQuery{}); !errors.Is(err, want) {
		t.Fatalf("query error = %v, want %v", err, want)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresNearbyStoreRejectsMalformedRows(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery("FROM bike_stations").WithArgs(0.0, 0.0, 0, 0).
		WillReturnRows(pgxmock.NewRows([]string{"id", "name", "city", "geodesic_meters", "lon", "lat"}).
			AddRow("S-1", "Station", "Taipei", "invalid-distance", 121.51, 25.01)).RowsWillBeClosed()
	if _, err := NewPostgresNearbyStore(db).Find(t.Context(), _nearbyBike, NearbyQuery{}); err == nil {
		t.Fatal("malformed distance produced a nearby candidate")
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
