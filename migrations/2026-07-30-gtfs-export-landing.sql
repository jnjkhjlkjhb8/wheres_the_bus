-- 2026-07-30-gtfs-export-landing.sql
-- Landing tables for the GTFS export datasets (datasetSpec.exportOnly).
-- Hand-applied to Azure: psql "$DATABASE_URL" -f migrations/2026-07-30-gtfs-export-landing.sql
--
-- These seven tables were created out of band on Azure before this file existed.
-- Every CREATE TABLE below matches the live shape exactly (column names, order,
-- and types, from information_schema on 2026-07-30), so on Azure they no-op and
-- on a fresh database they reproduce the live shape — the same reconciliation
-- pattern as 2026-07-04-raw-tdx-schema.sql. Without this file a bootstrapped
-- environment would be missing them entirely.
--
-- What the file does add on Azure is fetched_at and its trigger: the seven were
-- created without either, and every other raw_tdx landing table carries both.
--
-- These tables have no loader. The GTFS feed builder reads raw_tdx directly, so
-- they are landed and never transformed into a PG_SCHEMA target — see
-- datasetSpec.exportOnly in services/functions/dataset.go.
--
-- Three further export tables (metro_stationtimetable, tra_line,
-- tra_stationofline) are not in this file; they are FDPL-4.

-- ============================================================================
-- Metro export tables. Partitioned by `system` (the TDX RailSystem code), landed
-- for TRTC, KRTC, TYMC, TMRT, NTMC — see ingestMetroGTFS.
-- ============================================================================

-- /v2/Rail/Metro/Route/{RailSystem}: operating routes. RouteID is not a primary
-- key on its own — each RouteID appears once per direction. This, not
-- metro_line, is the routes.txt source: branches and short workings (Xinbeitou,
-- Xiaobitan, Daan-Beitou) exist only at this level.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_route (
    system           text,
    srcupdatetime    timestamptz,
    updatetime       timestamptz,
    versionid        integer,
    routeid          text,
    operatorcode     text,
    routename        jsonb,
    railroutetype    smallint,
    lineno           text,
    lineid           text,
    direction        smallint,
    startstationid   text,
    startstationname jsonb,
    endstationid     text,
    endstationname   jsonb,
    traveltime       integer,
    routelength      integer
);

-- /v2/Rail/Metro/StationOfRoute/{RailSystem}: the ordered station list of one
-- route in one direction. The nested Stations array carries CumulativeDistance
-- in kilometres, which is the shape_dist_traveled source (metro_route.routelength
-- is 0 on every observed row and must not be used for it).
CREATE TABLE IF NOT EXISTS raw_tdx.metro_stationofroute (
    system        text,
    srcupdatetime timestamptz,
    updatetime    timestamptz,
    versionid     integer,
    lineno        text,
    lineid        text,
    routeid       text,
    routename     jsonb,
    direction     smallint,
    stations      jsonb
);

-- /v2/Rail/Metro/Line/{RailSystem}: branded lines. Landed only for linecolor,
-- which metro_route does not carry; TRTC returns 5 rows against metro_route's 22.
-- linesectionname is an empty object on every observed row.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_line (
    system          text,
    srcupdatetime   timestamptz,
    updatetime      timestamptz,
    versionid       integer,
    lineno          text,
    lineid          text,
    linename        jsonb,
    linesectionname jsonb,
    linecolor       text,
    isbranch        boolean
);

-- /v2/Rail/Metro/Frequency/{RailSystem}: headway bands per route and service-day
-- class. There is no direction column — one row covers both directions. The
-- nested headways array is not ordered by time and its peak and off-peak bands
-- interleave, so consumers must sort it.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_frequency (
    system        text,
    srcupdatetime timestamptz,
    updatetime    timestamptz,
    versionid     integer,
    lineno        text,
    lineid        text,
    routeid       text,
    traintype     smallint,
    serviceday    jsonb,
    operationtime jsonb,
    headways      jsonb
);

-- /v2/Rail/Metro/StationExit/{RailSystem}: one row per exit, keyed
-- (stationid, exitid), with WGS84 coordinates in exitposition. These become
-- GTFS entrances (location_type=2) so first/last-mile walking routes to the
-- right side of a station rather than its centroid.
--
-- escalator is smallint here and boolean on thsr_stationexit: TDX serves a count
-- for Metro and a flag for THSR. The two tables keep their source types rather
-- than forcing a shared one.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_stationexit (
    system              text,
    srcupdatetime       timestamptz,
    updatetime          timestamptz,
    versionid           integer,
    stationid           text,
    stationname         jsonb,
    exitid              text,
    exitname            jsonb,
    exitposition        jsonb,
    locationdescription text,
    stair               boolean,
    escalator           smallint,
    elevator            boolean,
    exitmapurls         jsonb
);

-- ============================================================================
-- Unpartitioned rail export tables.
-- ============================================================================

-- /v2/Rail/THSR/StationExit. Same shape as metro_stationexit minus versionid,
-- which THSR does not serve, and with escalator as a boolean (see above).
CREATE TABLE IF NOT EXISTS raw_tdx.thsr_stationexit (
    stationid           text,
    stationname         jsonb,
    exitid              text,
    exitname            jsonb,
    exitposition        jsonb,
    locationdescription text,
    stair               boolean,
    escalator           boolean,
    elevator            boolean,
    exitmapurls         jsonb,
    srcupdatetime       timestamptz,
    updatetime          timestamptz
);

-- /v2/Rail/Operator: every rail operator, the agency.txt source. operatorid is
-- not unique (providerid 049 and 050 both carry operatorid NTMC); key on
-- providerid.
CREATE TABLE IF NOT EXISTS raw_tdx.rail_operator (
    providerid        text,
    operatorid        text,
    operatorname      jsonb,
    operatorphone     text,
    operatoremail     text,
    operatorurl       text,
    reservationurl    text,
    reservationphone  text,
    operatorcode      text,
    authoritycode     text,
    subauthoritycode  text,
    operatorno        text,
    updatetime        timestamptz
);

-- ============================================================================
-- fetched_at and its trigger.
--
-- The DEFAULT alone is insufficient: dumpRawTDX lands rows with
-- `INSERT ... SELECT * FROM jsonb_populate_recordset(NULL::raw_tdx.T, ...)`, and
-- since the TDX payload has no fetched_at key that SELECT * supplies an explicit
-- NULL, bypassing the DEFAULT and violating NOT NULL. raw_tdx.set_fetched_at()
-- (created in 2026-07-04-raw-tdx-schema.sql) fills it on insert. Same reasoning
-- as that file and 2026-07-09-metro-s2s-transfer.sql.
-- ============================================================================

ALTER TABLE raw_tdx.metro_route          ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_stationofroute ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_line           ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_frequency      ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_stationexit    ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.thsr_stationexit     ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.rail_operator        ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'metro_route','metro_stationofroute','metro_line','metro_frequency',
    'metro_stationexit','thsr_stationexit','rail_operator'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_fetched_at ON raw_tdx.%I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.%I '
      || 'FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at()', t);
  END LOOP;
END;
$$;

-- ============================================================================
-- Partition indexes. The landing lifecycle is DELETE WHERE system = $1 followed
-- by INSERT, so the five partitioned tables need their partition column indexed;
-- the two unpartitioned ones are TRUNCATE-replaced and need nothing.
-- ============================================================================

CREATE INDEX IF NOT EXISTS metro_route_system_idx          ON raw_tdx.metro_route (system);
CREATE INDEX IF NOT EXISTS metro_stationofroute_system_idx ON raw_tdx.metro_stationofroute (system);
CREATE INDEX IF NOT EXISTS metro_line_system_idx           ON raw_tdx.metro_line (system);
CREATE INDEX IF NOT EXISTS metro_frequency_system_idx      ON raw_tdx.metro_frequency (system);
CREATE INDEX IF NOT EXISTS metro_stationexit_system_idx    ON raw_tdx.metro_stationexit (system);
