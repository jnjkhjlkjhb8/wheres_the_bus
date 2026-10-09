DROP INDEX IF EXISTS idx_bike_stations_geom;
DROP INDEX IF EXISTS idx_bus_stations_geom;
DROP INDEX IF EXISTS uq_sub_route_stop_dir;

CREATE INDEX IF NOT EXISTS idx_tra_timetable_station
    ON tra_timetable (stationid, train_date, arrivaltime);
CREATE INDEX IF NOT EXISTS idx_thsr_timetable_station
    ON thsr_timetable (stationid, train_date, arrivaltime);
CREATE INDEX IF NOT EXISTS idx_bssm_station_name
    ON bus_station_stop_map (station_name);
CREATE INDEX IF NOT EXISTS idx_eta_history_recorded
    ON bus_eta_history (recorded_at);

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_search_vector_name_trgm
    ON search_vector USING gin (name gin_trgm_ops);

ALTER TABLE bus_schedule
    ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT NOW();
ALTER TABLE bus_schedule
    ADD CONSTRAINT bus_schedule_natural_key
    UNIQUE (sub_route_uid, direction, type, service_day, tripid, "stop_uid/MinHeadwayMins");

ALTER TABLE mrt_schedule
    ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT NOW();
ALTER TABLE mrt_schedule
    ADD CONSTRAINT mrt_schedule_natural_key
    UNIQUE (station_id, lineid, destinationstaionid, serviceday, system);
