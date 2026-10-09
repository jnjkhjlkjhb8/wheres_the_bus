CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bus_station_groups_geog
    ON bus_station_groups USING gist (("position"::geography));
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bike_stations_geog
    ON bike_stations USING gist ((geom::geography));
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mrt_station_geog
    ON mrt_station USING gist ((stationposition::geography));
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tra_stations_geog
    ON tra_stations USING gist ((geom::geography));
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_thsr_stations_geog
    ON thsr_stations USING gist ((geom::geography));

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_search_vector_depart_trgm
    ON search_vector USING gin (depart gin_trgm_ops);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_search_vector_destin_trgm
    ON search_vector USING gin (destin gin_trgm_ops);

DROP INDEX CONCURRENTLY IF EXISTS bus_schedule_idx_unique;
DROP INDEX CONCURRENTLY IF EXISTS bus_station_stop_map_unique_idx;
