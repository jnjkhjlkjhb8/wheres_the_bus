-- 2026-08-08-drop-unread-export-tables.sql
-- Drop the three GTFS export landing tables nothing ever read (FDPL-69).
-- Hand-applied to Azure: psql "$DATABASE_URL" -f migrations/2026-08-08-drop-unread-export-tables.sql
--
-- ORDER OF OPERATIONS. Apply this AFTER deploying the functions image that
-- removes the three datasets from datasetRegistry — the reverse of how
-- 2026-07-30-gtfs-export-timetable.sql was applied. An image still holding the
-- registry entries would land into tables that no longer exist and fail three
-- partitions a night. Applying it late costs nothing: the tables simply keep
-- taking writes nobody reads until the drop lands.
--
-- These were added by 2026-07-30-gtfs-export-timetable.sql for a feed builder
-- that never came to read them. The metro half of the feed is built from routes,
-- stations and headways, and the real per-train metro times are coming from
-- TDX's published GTFS rather than from a per-station timetable; TRA's line and
-- station-of-line sets were landed for a rail route model the feed does not use
-- (rail routes are train types, not lines). Between them they were ~40 MB of
-- nightly writes on a 2 GB instance, for nothing.
--
-- Nothing outside raw_tdx references them: no views, no foreign keys, no loader.
-- Recovering one is a re-land, not a restore, so no backup step is needed.
--
-- Not marked "-- REPLAY: skip": this is a schema change, not a one-shot data
-- cleanup, and a fresh environment should end up without these tables rather
-- than with three that nothing writes to.
--
-- What is about to go, if you want to look first:
--   SELECT relname, pg_size_pretty(pg_total_relation_size(oid))
--   FROM pg_class
--   WHERE relnamespace = 'raw_tdx'::regnamespace
--     AND relname IN ('metro_stationtimetable', 'tra_line', 'tra_stationofline');

BEGIN;

DROP TABLE IF EXISTS raw_tdx.metro_stationtimetable;
DROP TABLE IF EXISTS raw_tdx.tra_line;
DROP TABLE IF EXISTS raw_tdx.tra_stationofline;

-- The landing bookkeeping outlives the tables it describes: landing_state is
-- keyed by table_name, not by a foreign key, so these rows would otherwise sit
-- there forever holding Last-Modified values for datasets nothing fetches. The
-- metro one has a row per system partition; the two TRA ones are unpartitioned.
DELETE FROM raw_tdx.landing_state
WHERE table_name IN ('metro_stationtimetable', 'tra_line', 'tra_stationofline');

COMMIT;
