-- Bus static loader contract fixes.
-- Apply before deploying the atomic loader binary: circular routes may contain
-- intentional duplicate schedule natural keys, so bus_schedule is a
-- partition-replace table, not an upsert table.

DO $migration$
BEGIN
    IF to_regclass('bus_schedule') IS NOT NULL THEN
        ALTER TABLE bus_schedule
            DROP CONSTRAINT IF EXISTS bus_schedule_natural_key;
    END IF;
END
$migration$;

CREATE INDEX IF NOT EXISTS bus_schedule_route_lookup_idx
    ON bus_schedule (sub_route_uid, direction, service_day);

-- The live read-only audit found no FK backed by
-- bus_station_stop_map_unique_idx. Recheck that invariant at apply time and
-- fail closed if a later schema added a dependency. The table's primary key
-- (sub_route_uid, stop_uid, direction) remains the writer conflict target.
DO $migration$
DECLARE
    unique_constraint oid;
    supporting_index oid;
    dependent_fk text;
BEGIN
    IF to_regclass('bus_station_stop_map') IS NULL THEN
        RETURN;
    END IF;

    SELECT c.oid, c.conindid
      INTO unique_constraint, supporting_index
      FROM pg_constraint c
     WHERE c.conrelid = 'bus_station_stop_map'::regclass
       AND c.conname = 'bus_station_stop_map_unique_idx'
       AND c.contype IN ('u', 'p');

    IF unique_constraint IS NULL THEN
        RETURN;
    END IF;

    SELECT format('%I.%I', n.nspname, c.conname)
      INTO dependent_fk
      FROM pg_constraint c
      JOIN pg_class rel ON rel.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = rel.relnamespace
     WHERE c.contype = 'f'
       AND c.conindid = supporting_index
     LIMIT 1;

    IF dependent_fk IS NOT NULL THEN
        RAISE EXCEPTION
            'cannot drop bus_station_stop_map_unique_idx; referenced by foreign key %',
            dependent_fk;
    END IF;

    ALTER TABLE bus_station_stop_map
        DROP CONSTRAINT bus_station_stop_map_unique_idx;
END
$migration$;
