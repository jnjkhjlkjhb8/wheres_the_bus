-- TRTC OD travel time source. The Metro ODFare feed omits TravelTime for TRTC
-- (100% NULL in raw_tdx.metro_odfare; KRTC/KLRT carry it), so mrt_journey_matrix
-- .travel_time_min stays at its DEFAULT 0 for every Taipei-metro pair. These two
-- landing tables hold the graph inputs the loader (services/functions/mrt.go,
-- loadMrtTrtcTravelTime) uses to compute TRTC OD times: adjacent-station hop
-- times and interchange transfer times. Only TRTC is landed here; the other
-- operators already have per-OD times from ODFare. Columns are the lowercased
-- TDX top-level keys (landing lowercases only the top level; nested arrays/objects
-- stay jsonb). Idempotent (CREATE ... IF NOT EXISTS).

-- /v2/Rail/Metro/S2STravelTime/{Operator}: per-line adjacent-station segments.
-- The nested TravelTimes array is kept as jsonb; the loader decodes it in Go with
-- case-insensitive struct tags.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_s2straveltime (
    system        text,
    srcupdatetime timestamptz,
    updatetime    timestamptz,
    versionid     integer,
    lineno        text,
    lineid        text,
    routeid       text,
    traintype     smallint,
    traveltimes   jsonb
);

-- /v2/Rail/Metro/LineTransfer/{Operator}: interchange edges between two station
-- IDs. TransferTime is whole minutes per the TDX schema.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_linetransfer (
    system              text,
    srcupdatetime       timestamptz,
    updatetime          timestamptz,
    versionid           integer,
    fromlineno          text,
    fromlineid          text,
    fromlinename        jsonb,
    fromstationid       text,
    fromstationname     jsonb,
    tolineno            text,
    tolineid            text,
    tolinename          jsonb,
    tostationid         text,
    tostationname       jsonb,
    isonsitetransfer    smallint,
    transfertime        smallint,
    transferdescription text
);

-- fetched_at is required: landing inserts it (as NULL) and the loader SELECTs it
-- and staleness-gates on it. Separate ALTER so tables created by hand before this
-- migration (without fetched_at) still get the column.
ALTER TABLE raw_tdx.metro_s2straveltime ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE raw_tdx.metro_linetransfer  ADD COLUMN IF NOT EXISTS fetched_at timestamptz NOT NULL DEFAULT now();

-- fetched_at fill trigger: the DEFAULT alone is insufficient because landing
-- inserts an explicit NULL (see 2026-07-04-raw-tdx-schema.sql). set_fetched_at()
-- already exists from that migration. Bare table names in the array so raw_tdx.%I
-- qualifies them correctly.
DO $$
DECLARE
  t text;
  tables text[] := ARRAY['metro_s2straveltime','metro_linetransfer'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_fetched_at ON raw_tdx.%I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.%I '
      || 'FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at()', t);
  END LOOP;
END;
$$;
