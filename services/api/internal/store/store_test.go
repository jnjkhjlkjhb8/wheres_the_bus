package store

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/pashagolub/pgxmock/v4"
)

// TestBusStaticPayloadReturnsBytes verifies the read path returns the stored
// static blob verbatim for the requested sub-route.
func TestBusStaticPayloadReturnsBytes(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	want := []byte("serialized-subroute")
	db.ExpectQuery("SELECT pb FROM bus_static WHERE sub_route_uid").
		WithArgs("SR-1").
		WillReturnRows(pgxmock.NewRows([]string{"pb"}).AddRow(want))

	got, err := BusStaticPayload(context.Background(), db, "SR-1")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("payload = %q, want %q", got, want)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBusStaticPayloadMissingRow verifies a missing sub-route surfaces
// pgx.ErrNoRows so the handler maps it to NotFound.
func TestBusStaticPayloadMissingRow(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT pb FROM bus_static WHERE sub_route_uid").
		WithArgs("missing").
		WillReturnRows(pgxmock.NewRows([]string{"pb"}))

	_, err = BusStaticPayload(context.Background(), db, "missing")
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("err = %v, want pgx.ErrNoRows", err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBusStationGroupCityResolves verifies the city lookup used to key the
// live-ETA stream when the request omits the city.
func TestBusStationGroupCityResolves(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT city FROM bus_station_groups WHERE group_uid").
		WithArgs("G-1").
		WillReturnRows(pgxmock.NewRows([]string{"city"}).AddRow("Taipei"))

	city, err := BusStationGroupCity(context.Background(), db, "G-1")
	if err != nil {
		t.Fatal(err)
	}
	if city != "Taipei" {
		t.Fatalf("city = %q, want Taipei", city)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBusStationGroupHeaderReturnsFields verifies the group header row maps its
// columns (name, city, position) into the struct fields.
func TestBusStationGroupHeaderReturnsFields(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT group_name, city").
		WithArgs("G-1").
		WillReturnRows(pgxmock.NewRows([]string{"group_name", "city", "st_x", "st_y"}).
			AddRow("Taipei Main", "Taipei", 121.5, 25.05))

	h, err := BusStationGroupHeader(context.Background(), db, "G-1")
	if err != nil {
		t.Fatal(err)
	}
	if h.GroupName != "Taipei Main" || h.City != "Taipei" || h.Lon != 121.5 || h.Lat != 25.05 {
		t.Fatalf("header = %+v, want name/city/pos populated", h)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBusStationGroupHeaderMissing verifies a missing group surfaces an error so
// the handler maps it to NotFound.
func TestBusStationGroupHeaderMissing(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT group_name, city").
		WithArgs("missing").
		WillReturnRows(pgxmock.NewRows([]string{"group_name", "city", "st_x", "st_y"}))

	if _, err := BusStationGroupHeader(context.Background(), db, "missing"); err == nil {
		t.Fatal("want error for missing group, got nil")
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBusStationGroupMembersMapsRows verifies member rows are mapped into the
// proto members in the ordered result.
func TestBusStationGroupMembersMapsRows(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("FROM bus_station_group_members").
		WithArgs("G-1").
		WillReturnRows(pgxmock.NewRows([]string{"station_uid", "station_id", "station_name", "st_x", "st_y"}).
			AddRow("U-1", "S-1", "Stop A", 121.1, 25.1).
			AddRow("U-2", "S-2", "Stop B", 121.2, 25.2))

	members, err := BusStationGroupMembers(context.Background(), db, "G-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 2 {
		t.Fatalf("members = %d, want 2", len(members))
	}
	if members[0].StationUid != "U-1" || members[0].StationName != "Stop A" || members[0].PositionLon != 121.1 {
		t.Fatalf("member[0] = %+v, want U-1 Stop A", members[0])
	}
	if members[1].StationId != "S-2" || members[1].PositionLat != 25.2 {
		t.Fatalf("member[1] = %+v, want S-2", members[1])
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBikeStaticDataReturnsFields verifies the bike static row maps its columns
// into the struct the handler copies onto the proto response.
func TestBikeStaticDataReturnsFields(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	lat, lon := 25.033, 121.565
	db.ExpectQuery("SELECT name,capacity,service_type,address,ST_Y\\(geom\\),ST_X\\(geom\\) FROM bike_stations").
		WithArgs("B-1").
		WillReturnRows(pgxmock.NewRows([]string{"name", "capacity", "service_type", "address", "lat", "lon"}).
			AddRow("YouBike Stop", int32(30), int32(2), "1 Main St", &lat, &lon))

	row, err := BikeStaticData(context.Background(), db, "B-1")
	if err != nil {
		t.Fatal(err)
	}
	if row.Name != "YouBike Stop" || row.Capacity != 30 || row.ServiceType != 2 || row.Address != "1 Main St" {
		t.Fatalf("row = %+v, want fields populated", row)
	}
	if row.Lat == nil || row.Lon == nil || *row.Lat != lat || *row.Lon != lon {
		t.Fatalf("row lat/lon = %v/%v, want %v/%v", row.Lat, row.Lon, lat, lon)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBikeStaticDataMissing verifies a missing station surfaces pgx.ErrNoRows so
// the handler maps it to NotFound.
func TestBikeStaticDataMissing(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT name,capacity,service_type,address,ST_Y\\(geom\\),ST_X\\(geom\\) FROM bike_stations").
		WithArgs("missing").
		WillReturnRows(
			pgxmock.NewRows([]string{"name", "capacity", "service_type", "address", "lat", "lon"}),
		)

	if _, err := BikeStaticData(context.Background(), db, "missing"); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("err = %v, want pgx.ErrNoRows", err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestBikeStaticDataNullGeom verifies a station landed without a point scans as
// nil rather than 0, so the handler leaves the proto's Lat/Lon empty instead of
// reporting the null island off West Africa as the station's location.
func TestBikeStaticDataNullGeom(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("SELECT name,capacity,service_type,address,ST_Y\\(geom\\),ST_X\\(geom\\) FROM bike_stations").
		WithArgs("B-2").
		WillReturnRows(
			pgxmock.NewRows([]string{"name", "capacity", "service_type", "address", "lat", "lon"}).
				AddRow("No Geom", int32(10), int32(2), "", nil, nil),
		)

	row, err := BikeStaticData(context.Background(), db, "B-2")
	if err != nil {
		t.Fatal(err)
	}
	if row.Lat != nil || row.Lon != nil {
		t.Fatalf("row lat/lon = %v/%v, want nil/nil", row.Lat, row.Lon)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
