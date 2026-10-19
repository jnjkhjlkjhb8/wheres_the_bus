CREATE TABLE IF NOT EXISTS mrt_journey_matrix (
    id               TEXT PRIMARY KEY,
    from_station_id  TEXT NOT NULL,
    to_station_id    TEXT NOT NULL,
    system           TEXT NOT NULL,
    travel_time_min  INTEGER NOT NULL,
    fare_nt          INTEGER NOT NULL,
    updated_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mrt_journey_matrix_natural_key
    ON mrt_journey_matrix (from_station_id, to_station_id, system);
