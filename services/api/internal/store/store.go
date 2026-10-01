package store

import (
	"context"

	"github.com/jackc/pgx/v5"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

// DB is the read surface the bus, bike, and station-group handlers need.
// Both *pgxpool.Pool and the pgxmock pool satisfy it, so the read-path helpers
// can be unit-tested with a mock.
type DB interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

func BusStaticPayload(ctx context.Context, db DB, subRouteUID string) ([]byte, error) {
	var data []byte
	if err := db.QueryRow(ctx, `SELECT pb FROM bus_static WHERE sub_route_uid = $1;`, subRouteUID).Scan(&data); err != nil {
		return nil, err
	}
	return data, nil
}

// BusStationGroupCity resolves a station group's city from the loaded env
// schema, used to key the live-ETA stream when the request omits the city.
func BusStationGroupCity(ctx context.Context, db DB, groupUID string) (string, error) {
	var city string
	if err := db.QueryRow(ctx, `SELECT city FROM bus_station_groups WHERE group_uid = $1`, groupUID).Scan(&city); err != nil {
		return "", err
	}
	return city, nil
}

type BusStationGroupHeaderRow struct {
	GroupName string
	City      string
	Lon       float64
	Lat       float64
}

// BusStationGroupHeader reads a station group's name, city, and position. A
// missing group surfaces as pgx.ErrNoRows for the caller to map to NotFound.
func BusStationGroupHeader(ctx context.Context, db DB, groupUID string) (BusStationGroupHeaderRow, error) {
	var r BusStationGroupHeaderRow
	err := db.QueryRow(ctx, `
		SELECT group_name, city, ST_X(position), ST_Y(position)
		FROM bus_station_groups
		WHERE group_uid = $1`, groupUID).Scan(&r.GroupName, &r.City, &r.Lon, &r.Lat)
	return r, err
}

// BusStationGroupMembers reads the member stops of a station group, ordered for
// stable presentation.
func BusStationGroupMembers(ctx context.Context, db DB, groupUID string) ([]*pb.Bus_StationGroupMember, error) {
	rows, err := db.Query(ctx, `
		SELECT station_uid, station_id, station_name, ST_X(position), ST_Y(position)
		FROM bus_station_group_members
		WHERE group_uid = $1
		ORDER BY station_id, station_uid`, groupUID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var members []*pb.Bus_StationGroupMember
	for rows.Next() {
		m := &pb.Bus_StationGroupMember{}
		if err := rows.Scan(&m.StationUid, &m.StationId, &m.StationName, &m.PositionLon, &m.PositionLat); err != nil {
			return nil, err
		}
		members = append(members, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return members, nil
}

type BikeStaticRow struct {
	Name        string
	Capacity    int32
	ServiceType int32
	Address     string
	// Nullable: geom is not NOT NULL, and a station landed without a point
	// leaves both nil rather than reporting (0, 0) off West Africa.
	Lat *float64
	Lon *float64
}

// BikeStaticData reads a bike station's static fields from the loaded env
// schema. A missing station surfaces as pgx.ErrNoRows for the caller to map to
// NotFound.
func BikeStaticData(ctx context.Context, db DB, stationUID string) (BikeStaticRow, error) {
	var r BikeStaticRow
	err := db.QueryRow(ctx, `SELECT name,capacity,service_type,address,ST_Y(geom),ST_X(geom) FROM bike_stations WHERE station_uid = $1;`, stationUID).
		Scan(&r.Name, &r.Capacity, &r.ServiceType, &r.Address, &r.Lat, &r.Lon)
	return r, err
}
