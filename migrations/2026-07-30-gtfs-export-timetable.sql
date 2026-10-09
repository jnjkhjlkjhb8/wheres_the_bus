-- 2026-07-30-gtfs-export-timetable.sql
-- The three remaining GTFS export landing tables (FDPL-4). Apply after
-- 2026-07-30-gtfs-export-landing.sql.
-- Hand-applied to Azure: psql "$DATABASE_URL" -f migrations/2026-07-30-gtfs-export-timetable.sql
--
-- ORDER OF OPERATIONS. Apply this before deploying the functions image that
-- registers these three datasets. The registry entries land straight into these
-- tables, so an image deployed first produces three nightly landing failures
-- until the tables exist. Nothing is lost by the gap — the next run refetches —
-- but the errors are noise.
--
-- Like the other export tables these have no loader: the GTFS feed builder reads
-- raw_tdx directly (datasetSpec.exportOnly).

-- /v2/Rail/Metro/StationTimeTable/{RailSystem}: every departure from one station,
-- on one route, in one direction, for one service-day class. The nested
-- timetables array holds {Sequence, ArrivalTime, DepartureTime, TrainType} per
-- departure, with StoppingPatternID additionally on TYMC.
--
-- Two properties of this feed drive how it must be consumed:
--
--   * There is no train identifier. Sequence is the Nth departure of the day AT
--     THAT STATION, not a trip id, and it does not align across stations: on the
--     Bannan line's Direction 1, BL02 serves 171 departures against BL03's 170
--     because one train originates at BL02, so BL02's Nth departure is BL03's
--     (N-1)th from there on. Joining stations on Sequence produces trips that
--     silently do not exist. Metro stop_times are instead built from the origin
--     station's departure list, with downstream times derived from
--     raw_tdx.metro_s2straveltime segment running times.
--
--   * ArrivalTime is absent on TRTC and present on KRTC and TYMC, so a shared
--     decode must treat a missing arrival as equal to the departure. Metro dwell
--     is 20-30 seconds, so the substitution is immaterial for routing.
--
-- destinationstaionid reproduces TDX's misspelling of "Station"; the landing
-- INSERT matches JSON keys to column names, so correcting it would silently land
-- NULLs. raw_tdx.metro_schedule carries the same typo for the same reason.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_stationtimetable (
    system                 text,
    srcupdatetime          timestamptz,
    updatetime             timestamptz,
    versionid              integer,
    routeid                text,
    lineid                 text,
    stationid              text,
    stationname            jsonb,
    direction              smallint,
    destinationstaionid    text,
    destinationstationname jsonb,
    serviceday             jsonb,
    timetables             jsonb
);

-- /v2/Rail/TRA/Line: the 12 TRA lines, the routes.txt source for TRA. Unlike the
-- Metro endpoints TRA serves flat Zh/En text rather than a nested multilingual
-- object, so these are text columns and not jsonb. lineno is empty on every
-- observed row; linesectionname is descriptive prose and does not agree with the
-- line's actual endpoints (SA reads "Ruifang-Shen'ao" while StationOfLine ends at
-- Badouzi), so it must not be used to derive terminals.
CREATE TABLE IF NOT EXISTS raw_tdx.tra_line (
    lineno            text,
    lineid            text,
    linenamezh        text,
    linenameen        text,
    linesectionnamezh text,
    linesectionnameen text,
    isbranch          boolean,
    updatetime        timestamptz
);

-- /v2/Rail/TRA/StationOfLine: each line's ordered stations, with
-- TraveledDistance in cumulative kilometres. Sequence starts at 0 here and at 1
-- on the Metro endpoints. There is no direction column — one row per line covers
-- a single ordering. A station on two lines appears once in each line's array
-- under the same StationID, so stops.txt keys on StationID with no deduplication
-- needed.
CREATE TABLE IF NOT EXISTS raw_tdx.tra_stationofline (
    lineno     text,
    lineid     text,
    stations   jsonb,
    updatetime timestamptz
);

-- ============================================================================
-- fetched_at and its trigger. The DEFAULT alone is insufficient: the landing
-- INSERT ... SELECT * FROM jsonb_populate_recordset(...) supplies an explicit
-- NULL for the column the TDX payload has no key for, bypassing the DEFAULT and
-- violating NOT NULL. raw_tdx.set_fetched_at() comes from
-- 2026-07-04-raw-tdx-schema.sql.
-- ============================================================================

ALTER TABLE raw_tdx.metro_stationtimetable ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.tra_line               ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.tra_stationofline      ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();

DO $$
DECLARE
  t text;
  tables text[] := ARRAY['metro_stationtimetable','tra_line','tra_stationofline'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_fetched_at ON raw_tdx.%I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.%I '
      || 'FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at()', t);
  END LOOP;
END;
$$;

-- metro_stationtimetable lands per system (DELETE WHERE system = $1, then
-- INSERT), so its partition column is indexed. The two TRA tables are
-- unpartitioned and TRUNCATE-replaced.
CREATE INDEX IF NOT EXISTS metro_stationtimetable_system_idx ON raw_tdx.metro_stationtimetable (system);
