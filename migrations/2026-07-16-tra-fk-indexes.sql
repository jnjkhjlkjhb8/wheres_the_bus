-- Adds supporting indexes for FK-style lookups the live schema audit found
-- missing on the TRA tables. TRA is a pure read path (ADR-0005): rail
-- queries in services/router (maas.go OD-fare joins, tra.go timetable
-- lookups) filter/join on these columns without an index today, forcing a
-- sequential scan of tra_fares / tra_timetable per request.
--
--   tra_fares(destination_station_id)   -- services/router/maas.go OD-fare join
--   tra_timetable(starting_station_id)  -- services/router/tra.go timetable lookup
--   tra_timetable(ending_station_id)    -- services/router/tra.go timetable lookup
--
-- CONCURRENTLY must run outside a transaction block. Idempotent
-- (IF NOT EXISTS).

\set ON_ERROR_STOP on

DO $schema_check$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'search_path must resolve a target schema; set PGOPTIONS=''-c search_path=<schema>'' before applying';
    END IF;
END
$schema_check$;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tra_fares_destination_station_id
    ON tra_fares (destination_station_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tra_timetable_starting_station_id
    ON tra_timetable (starting_station_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tra_timetable_ending_station_id
    ON tra_timetable (ending_station_id);
