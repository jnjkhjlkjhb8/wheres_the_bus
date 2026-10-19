-- 2026-07-04-raw-tdx-schema.sql
-- raw_tdx landing schema for two-stage static ingestion (ADR-0005).
-- Hand-applied to Azure: psql "$DATABASE_URL" -f migrations/2026-07-04-raw-tdx-schema.sql
--
-- Idempotent and non-destructive: reconciles the out-of-band live Azure schema
-- with the repo. The CREATE TABLE blocks for the 19 pre-existing tables match
-- the live schema exactly (column names AND types, from a pg_dump of Azure
-- raw_tdx taken 2026-07-04), so on Azure they no-op and on a fresh local DB
-- they recreate the live shape. On top of that the migration adds:
--   * fetched_at timestamptz NOT NULL DEFAULT now() on every table (staleness
--     signal for the 03:30 loader), filled by a BEFORE INSERT trigger — see the
--     fetched_at note below for why the DEFAULT alone is insufficient.
--   * the two missing landing tables: tra_station and thsr_odfare.
--   * traindate indexes on the two daily-timetable tables for the per-date
--     DELETE+INSERT partition lifecycle (wired in the landing code).
--
-- Type quirks preserved verbatim from live (do not "fix"):
--   * bus_station.updatetime and bus_station.versionid are text
--     (every other table has timestamptz / integer-family).
--   * tra_dailytimetable.traindate is text; thsr_dailytimetable.traindate is
--     timestamptz.
CREATE SCHEMA IF NOT EXISTS raw_tdx;

-- ============================================================================
-- Bus landing tables (live shape)
-- ============================================================================

CREATE TABLE IF NOT EXISTS raw_tdx.bus_route (
    city text,
    routeuid text,
    routeid text,
    hassubroutes boolean,
    operators jsonb,
    authorityid text,
    providerid text,
    subroutes jsonb,
    busroutetype integer,
    routename jsonb,
    departurestopnamezh text,
    departurestopnameen text,
    destinationstopnamezh text,
    destinationstopnameen text,
    ticketpricedescriptionzh text,
    ticketpricedescriptionen text,
    farebufferzonedescriptionzh text,
    farebufferzonedescriptionen text,
    routemapimageurl text,
    citycode text,
    updatetime timestamptz,
    versionid integer
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_stopofroute (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    operators jsonb,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    citycode text,
    stops jsonb,
    updatetime timestamptz,
    versionid smallint
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_shape (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    geometry text,
    encodedpolyline text,
    updatetime timestamptz,
    versionid integer
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_schedule (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    operatorid text,
    operatorcode text,
    operatorno text,
    timetables jsonb,
    frequencys jsonb,
    updatetime timestamptz,
    versionid integer
);

-- Live quirk: updatetime and versionid are text on this table only.
CREATE TABLE IF NOT EXISTS raw_tdx.bus_station (
    city text,
    stationuid text,
    stationid text,
    stationname jsonb,
    stationposition jsonb,
    stationaddress text,
    stationgroupid text,
    stops jsonb,
    locationcitycode text,
    bearing text,
    updatetime text,
    versionid text
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_stationgroup (
    city text,
    stationgroupuid text,
    stationgroupid text,
    stationgroupname jsonb,
    stationgroupposition jsonb,
    updatetime timestamptz,
    versionid integer
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_stop (
    city text,
    stopuid text,
    stopid text,
    authorityid text,
    stopname jsonb,
    stopposition jsonb,
    stopaddress text,
    bearing text,
    stationid text,
    stationgroupid text,
    stopdescription text,
    citycode text,
    locationcitycode text,
    updatetime timestamptz,
    versionid integer
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_operator (
    city text,
    providerid text,
    operatorid text,
    operatorname jsonb,
    operatorphone text,
    operatoremail text,
    operatorurl text,
    reservationurl text,
    reservationphone text,
    operatorcode text,
    authoritycode text,
    subauthoritycode text,
    operatorno text,
    updatetime timestamptz
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_routefare (
    city text,
    routeid text,
    routename text,
    operatorid text,
    operatorno text,
    subrouteid text,
    subroutename text,
    farepricingtype smallint,
    isfreebus smallint,
    isforallsubroutes smallint,
    sectionfares jsonb,
    stagefares jsonb,
    odfares jsonb,
    updatetime timestamptz
);

CREATE TABLE IF NOT EXISTS raw_tdx.bus_dailytimetable (
    city text,
    busdate timestamptz,
    routeuid text,
    routeid text,
    routename jsonb,
    operatorid text,
    operatorno text,
    operatorcode text,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    timetables jsonb,
    updatetime timestamptz
);

-- ============================================================================
-- Bike + Metro landing tables (live shape)
-- ============================================================================

CREATE TABLE IF NOT EXISTS raw_tdx.bike_station (
    city text,
    stationuid text,
    stationid text,
    authorityid text,
    stationname jsonb,
    stationposition jsonb,
    stationaddress jsonb,
    stopdescription text,
    bikescapacity smallint,
    servicetype smallint,
    srcupdatetime timestamptz,
    updatetime timestamptz
);

CREATE TABLE IF NOT EXISTS raw_tdx.metro_station (
    system text,
    stationposition jsonb,
    locationcity text,
    locationcitycode text,
    locationtown text,
    locationtowncode text,
    stationuid text,
    stationid text,
    stationname jsonb,
    stationaddress text,
    bikeallowonholiday boolean,
    srcupdatetime timestamptz,
    updatetime timestamptz,
    versionid integer
);

CREATE TABLE IF NOT EXISTS raw_tdx.metro_schedule (
    system text,
    srcupdatetime timestamptz,
    updatetime timestamptz,
    versionid integer,
    lineno text,
    lineid text,
    stationid text,
    stationname jsonb,
    tripheadsign text,
    destinationstaionid text,
    destinationstationname jsonb,
    traintype smallint,
    firsttraintime text,
    lasttraintime text,
    serviceday jsonb
);

CREATE TABLE IF NOT EXISTS raw_tdx.metro_odfare (
    system text,
    srcupdatetime timestamptz,
    updatetime timestamptz,
    versionid integer,
    originstationid text,
    originstationname jsonb,
    destinationstationid text,
    destinationstationname jsonb,
    traintype smallint,
    fares jsonb,
    traveltime text,
    traveldistance text
);

-- ============================================================================
-- Rail landing tables (live shape + the two NEW ones)
-- ============================================================================

-- /v2/Rail/TRA/Station — NEW landing table (inventory gap #2). Mirrors the
-- live thsr_station shape (same TDX Station schema family) minus stationphone,
-- which the shared railStation struct (rail.go L20) does not decode; the struct
-- does decode StationCode, so stationcode stays.
CREATE TABLE IF NOT EXISTS raw_tdx.tra_station (
    stationposition jsonb,
    locationcity text,
    locationcitycode text,
    locationtown text,
    locationtowncode text,
    stationuid text,
    stationid text,
    stationcode text,
    stationname jsonb,
    stationaddress text,
    operatorid text,
    updatetime timestamptz,
    versionid integer,
    fetched_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw_tdx.thsr_station (
    stationposition jsonb,
    locationcity text,
    locationcitycode text,
    locationtown text,
    locationtowncode text,
    stationuid text,
    stationid text,
    stationcode text,
    stationname jsonb,
    stationaddress text,
    stationphone text,
    operatorid text,
    updatetime timestamptz,
    versionid integer
);

CREATE TABLE IF NOT EXISTS raw_tdx.tra_odfare (
    originstationid text,
    originstationname jsonb,
    destinationstationid text,
    destinationstationname jsonb,
    direction smallint,
    fares jsonb,
    updatetime timestamptz,
    versionid integer
);

-- /v2/Rail/THSR/ODFare — NEW landing table (inventory gap #3). Columns are the
-- keys the transform struct decodes (rail.go L46): OriginStationID,
-- DestinationStationID, Fares[{TicketType,FareClass,CabinClass,Price}].
CREATE TABLE IF NOT EXISTS raw_tdx.thsr_odfare (
    originstationid text,
    destinationstationid text,
    fares jsonb,
    fetched_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw_tdx.tra_traintype (
    traintypeid text,
    traintypename jsonb,
    traintypecode text,
    updatetime timestamptz,
    versionid integer
);

-- Live quirk: traindate is text here but timestamptz on thsr_dailytimetable.
CREATE TABLE IF NOT EXISTS raw_tdx.tra_dailytimetable (
    traindate text,
    dailytraininfo jsonb,
    stoptimes jsonb,
    updatetime timestamptz,
    versionid smallint
);

CREATE TABLE IF NOT EXISTS raw_tdx.thsr_dailytimetable (
    traindate timestamptz,
    dailytraininfo jsonb,
    stoptimes jsonb,
    updatetime timestamptz,
    versionid integer
);

-- ============================================================================
-- fetched_at on every table (inventory gap #1).
-- ADD COLUMN IF NOT EXISTS makes this safe on both the live Azure schema and a
-- fresh local DB (the two new tables above already carry it inline; their
-- ALTERs no-op). fetched_at records the landing time — the staleness signal
-- the loader needs.
--
-- NOTE: the DEFAULT now() below is NOT sufficient on its own. dumpRawTDX lands
-- rows with `INSERT ... SELECT * FROM jsonb_populate_recordset(NULL::raw_tdx.T, ...)`
-- (main.go rawInsertSQL). SELECT * supplies a value for every column, and since
-- the raw JSON has no `fetched_at` key, jsonb_populate_recordset yields an
-- explicit NULL for it — which bypasses the column DEFAULT and would violate the
-- NOT NULL constraint, failing every landing dump. A BEFORE INSERT trigger (see
-- below) fills fetched_at when NULL, so the landing path needs no Go change and
-- fetched_at is always the true landing timestamp. If a later task rewrites the
-- INSERT to list columns explicitly (omitting fetched_at), the trigger becomes a
-- harmless no-op.
-- ============================================================================

ALTER TABLE raw_tdx.bus_route          ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_stopofroute    ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_shape          ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_schedule       ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_station        ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_stationgroup   ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_stop           ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_operator       ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_routefare      ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bus_dailytimetable ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.bike_station       ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_station      ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_schedule     ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_odfare       ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.tra_station        ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.thsr_station       ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.tra_odfare         ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.thsr_odfare        ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.tra_traintype      ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.tra_dailytimetable  ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.thsr_dailytimetable ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();

-- ============================================================================
-- Daily-timetable partition indexes.
-- The partition column is the existing `traindate` column (already landed from
-- the TDX payload) — no new column is added. The landing code's per-date
-- lifecycle (DELETE FROM ... WHERE traindate = $1; then INSERT, wired in
-- Task 2) and the loader's per-date SELECT both key on it. This works for both
-- tables without Go type gymnastics: the DELETE parameter is a YYYY-MM-DD
-- string, which Postgres compares directly against the text column
-- (tra_dailytimetable) and coerces to timestamptz for thsr_dailytimetable —
-- the same coercion jsonb_populate_recordset applies when landing the rows, so
-- DELETE and INSERT agree on the value.
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_raw_tra_dailytimetable_traindate  ON raw_tdx.tra_dailytimetable  (traindate);
CREATE INDEX IF NOT EXISTS idx_raw_thsr_dailytimetable_traindate ON raw_tdx.thsr_dailytimetable (traindate);

-- ============================================================================
-- fetched_at fill trigger (see the fetched_at note above for why the DEFAULT
-- alone is insufficient). Fires BEFORE INSERT on every landing table and sets
-- fetched_at to now() only when the incoming row leaves it NULL — which is what
-- dumpRawTDX's jsonb_populate_recordset always does. Idempotent: CREATE OR
-- REPLACE for the function, DROP TRIGGER IF EXISTS before each CREATE TRIGGER.
-- ============================================================================

CREATE OR REPLACE FUNCTION raw_tdx.set_fetched_at() RETURNS trigger AS $$
BEGIN
  IF NEW.fetched_at IS NULL THEN
    NEW.fetched_at := now();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'bus_route','bus_stopofroute','bus_shape','bus_schedule','bus_station',
    'bus_stationgroup','bus_stop','bus_operator','bus_routefare','bus_dailytimetable',
    'bike_station','metro_station','metro_schedule','metro_odfare',
    'tra_station','thsr_station','tra_odfare','thsr_odfare','tra_traintype',
    'tra_dailytimetable','thsr_dailytimetable'
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
