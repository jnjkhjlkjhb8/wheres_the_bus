package nearby

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/store"
)

type PostgresNearbyStore struct {
	db store.DB
}

func NewPostgresNearbyStore(db store.DB) *PostgresNearbyStore {
	return &PostgresNearbyStore{db: db}
}

type nearbyDBRow struct {
	ID             string  `db:"id"`
	Name           string  `db:"name"`
	City           string  `db:"city"`
	GeodesicMeters float64 `db:"geodesic_meters"`
	Lon            float64 `db:"lon"`
	Lat            float64 `db:"lat"`
}

func (s *PostgresNearbyStore) Find(ctx context.Context, mode NearbyMode, query NearbyQuery) ([]NearbyCandidate, error) {
	statement, err := nearbySQL(mode)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.Query(ctx, statement, query.Origin.Lon, query.Origin.Lat, query.RadiusMeters, query.Limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	dbRows, err := pgx.CollectRows(rows, pgx.RowToStructByName[nearbyDBRow])
	if err != nil {
		return nil, err
	}
	return nearbyCandidates(mode, dbRows), nil
}

func nearbyCandidates(mode NearbyMode, dbRows []nearbyDBRow) []NearbyCandidate {
	candidates := make([]NearbyCandidate, 0, len(dbRows))
	for _, row := range dbRows {
		candidates = append(candidates, NearbyCandidate{
			Mode: mode, ID: row.ID, Name: row.Name, City: row.City,
			Point: GeoPoint{Lon: row.Lon, Lat: row.Lat}, GeodesicMeters: row.GeodesicMeters,
		})
	}
	return candidates
}

func nearbySQL(mode NearbyMode) (string, error) {
	if mode == NearbyBus {
		return `SELECT group_uid AS id, group_name AS name, city,
			ST_Distance(position::geography, ST_SetSRID(ST_MakePoint($1,$2), 4326)::geography) AS geodesic_meters,
			ST_X(position) AS lon, ST_Y(position) AS lat
			FROM bus_station_groups g WHERE ST_DWithin(position::geography, ST_SetSRID(ST_MakePoint($1,$2), 4326)::geography, $3)
			AND EXISTS (SELECT 1 FROM bus_station_group_members m WHERE m.group_uid = g.group_uid)
			ORDER BY geodesic_meters LIMIT $4`, nil
	}
	type pointTable struct{ id, table, position string }
	table, ok := map[NearbyMode]pointTable{
		_nearbyBike: {"station_uid", "bike_stations", "geom"},
		_nearbyMRT:  {"station_id", "mrt_station", "stationposition"},
		_nearbyTRA:  {"station_id", "tra_stations", "geom"},
		_nearbyTHSR: {"station_id", "thsr_stations", "geom"},
	}[mode]
	if !ok {
		return "", _oops.With("mode", mode).Errorf("unknown nearby mode")
	}
	return nearbyPointSQL(table.id, "name", table.table, table.position), nil
}

func nearbyPointSQL(idColumn, nameColumn, table, positionColumn string) string {
	return fmt.Sprintf(`SELECT %s AS id, %s AS name, city,
		ST_Distance(%s::geography, ST_SetSRID(ST_MakePoint($1,$2), 4326)::geography) AS geodesic_meters,
		ST_X(%s) AS lon, ST_Y(%s) AS lat
		FROM %s WHERE ST_DWithin(%s::geography, ST_SetSRID(ST_MakePoint($1,$2), 4326)::geography, $3)
		ORDER BY geodesic_meters LIMIT $4`, idColumn, nameColumn, positionColumn, positionColumn, positionColumn, table, positionColumn)
}
