package nearby

import (
	"context"
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
