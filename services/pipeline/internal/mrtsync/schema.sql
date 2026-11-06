-- The copies PowerSync replicates from on powersync-db (ADR-0028). Applied by
-- the pipeline's mrt_sync step as mrt_sync, the owner of the mrt database, so
-- every statement is idempotent. Column types match the bus tables, except the
-- columns mrtsync.go derives; a test in this package checks them against
-- migrations/baseline.

CREATE TABLE IF NOT EXISTS mrt_schedule (
    system text NOT NULL,
    station_id text NOT NULL,
    lineid text NOT NULL,
    destinationstaionid text NOT NULL,
    serviceday smallint NOT NULL,
    firsttraintime text NOT NULL,
    lasttraintime text NOT NULL,
    -- The sync rules build the row id from these columns, so they are the key.
    PRIMARY KEY (system, station_id, lineid, destinationstaionid, serviceday)
);

CREATE TABLE IF NOT EXISTS mrt_journey_matrix (
    id text PRIMARY KEY,
    from_station_id text NOT NULL,
    to_station_id text NOT NULL,
    system text NOT NULL,
    fare_nt integer NOT NULL,
    half_fare_nt integer NOT NULL,
    travel_time_min integer NOT NULL
);

CREATE TABLE IF NOT EXISTS search_vector (
    type text NOT NULL,
    uid text NOT NULL,
    city text NOT NULL,
    name text NOT NULL,
    alias text,
    depart text,
    destin text,
    -- Derived from the bus table's geom; PowerSync has no geometry type.
    lat double precision,
    lon double precision,
    PRIMARY KEY (type, uid, city)
);

-- CREATE TABLE IF NOT EXISTS never changes a table that already exists: a
-- column added above also needs its own line here, e.g.
--   ALTER TABLE mrt_schedule ADD COLUMN IF NOT EXISTS <col> <type>;
-- Sync refuses to run while the live columns differ from what it writes.

GRANT SELECT ON mrt_schedule, mrt_journey_matrix, search_vector TO powersync_svc;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
        CREATE PUBLICATION powersync FOR TABLE mrt_schedule, mrt_journey_matrix, search_vector;
    END IF;
    -- CREATE PUBLICATION above only runs once; a table added later joins here.
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'powersync' AND schemaname = current_schema() AND tablename = 'search_vector'
    ) THEN
        ALTER PUBLICATION powersync ADD TABLE search_vector;
    END IF;
END
$$;
