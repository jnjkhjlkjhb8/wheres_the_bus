-- Read-path indexes the cluster lacks, duplicate bus_schedule indexes, and the
-- realtime write grant on bus_eta_prediction_error (FDPL-120).
--
-- The database restored from Azure never received
-- 2026-07-03-db-health-indexes.sql: the geography GiST indexes and the
-- depart/destin trigram indexes are missing, while two bus_schedule indexes that
-- file dropped are still there. CI replays the history and has them, so the
-- index statements below use the same names and are no-ops on a replayed
-- database. Measured on a restore of the 2026-10-09 dump (4 clients, prepared):
--
--   nearby bus station groups, 700 m     139 ms -> 0.47 ms
--   nearby bike stations, 700 m          8.9 ms -> 0.41 ms
--   text search, 3+ characters            30 ms -> 2 ms
--   nightly bus_schedule replace          12.3 s / ~650 MB WAL -> 7.6 s / ~490 MB
--
-- bus_schedule_idx_unique duplicates bus_schedule_scan_idx column for column,
-- and idx_bus_schedule is a prefix of bus_schedule_route_lookup_idx; neither
-- appears in any plan (BatchNextDepartures uses route_lookup and scan). Keep
-- bus_schedule_scan_idx: see 2026-07-16-bus-schedule-scan-index.sql.
--
-- realtime COPYs one row per prediction into bus_eta_prediction_error on every
-- tick, but the service-roles migration granted the table to pipeline_svc only,
-- so every insert failed with 42501. pipeline_svc only updates actuals and
-- deletes old rows, so it gives up INSERT and the table keeps one inserting
-- service.
--
-- CONCURRENTLY must run outside a transaction block; apply with plain
-- `psql -f`, as migrate-all does.

DO $schema_check$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'search_path must resolve a target schema; set PGOPTIONS=''-c search_path=<schema>'' before applying';
    END IF;
END
$schema_check$;

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
DROP INDEX CONCURRENTLY IF EXISTS idx_bus_schedule;

GRANT INSERT ON bus_eta_prediction_error TO realtime_svc;
GRANT USAGE, SELECT ON SEQUENCE bus_eta_prediction_error_id_seq TO realtime_svc;
REVOKE INSERT ON bus_eta_prediction_error FROM pipeline_svc;
