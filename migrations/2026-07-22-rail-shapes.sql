-- 2026-07-22-rail-shapes.sql
-- Rail line shapes for the MaaS transit-path feature: TDX /v2/Rail/Shape
-- (TRA), /v2/Rail/THSR/Shape, and /v2/Rail/Metro/Shape/{system} land in
-- raw_tdx, then the loader upserts them into this environment's rail_shapes
-- table so the router can clip a MaaS transit leg to the real line geometry
-- instead of drawing a straight line between stops.
--
-- Two parts:
--   1. raw_tdx.tra_shape / thsr_shape / metro_shape — shared landing tables,
--      same style as raw_tdx.bus_shape (2026-07-04-raw-tdx-schema.sql):
--      lowercase columns matching the TDX JSON keys, jsonb for nested
--      objects, WKT geometry kept as text (converted on load), fetched_at
--      bookkeeping with the standard fill trigger.
--   2. rail_shapes — one env-schema table (public and staging both apply
--      this file; see the schema_check guard, same pattern as
--      2026-07-16-pipeline-runs.sql). PostGIS geometry(Geometry,4326) since
--      metro shapes are MULTILINESTRING while TRA/THSR are LINESTRING.
--
-- Apply:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -v target_schema=public \
--       -f migrations/2026-07-22-rail-shapes.sql
--   PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--       -v target_schema=staging -f migrations/2026-07-22-rail-shapes.sql

\set ON_ERROR_STOP on

\if :{?target_schema}
\else
    \set target_schema _unset_
\endif

SELECT set_config('migration.target_schema', :'target_schema', false) AS target_schema_requested;

DO $schema_check$
DECLARE
    target text := current_setting('migration.target_schema', true);
BEGIN
    IF target = '_unset_' THEN
        RAISE EXCEPTION 'target_schema not set; apply with -v target_schema=staging|public matching the PGOPTIONS search_path';
    END IF;
    IF current_schema() IS DISTINCT FROM target THEN
        RAISE EXCEPTION 'current_schema() is % but target_schema is %; set PGOPTIONS=''-c search_path=%'' before applying',
            coalesce(current_schema(), '<none>'), target, target;
    END IF;
END
$schema_check$;

BEGIN;

-- ============================================================================
-- raw_tdx landing tables (shared, single copy regardless of target_schema).
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS raw_tdx;

-- /v2/Rail/Shape — TRA line shapes (12 rows: one per conventional-rail line,
-- including branch lines like Chengzhui). Unpartitioned, TRUNCATE lifecycle.
CREATE TABLE IF NOT EXISTS raw_tdx.tra_shape (
    lineno          text,
    lineid          text,
    linename        jsonb,
    geometry        text,
    encodedpolyline text,
    updatetime      timestamptz,
    fetched_at      timestamptz NOT NULL DEFAULT now()
);

-- /v2/Rail/THSR/Shape — the single high-speed rail line. No LineNo field.
CREATE TABLE IF NOT EXISTS raw_tdx.thsr_shape (
    lineid          text,
    linename        jsonb,
    geometry        text,
    encodedpolyline text,
    updatetime      timestamptz,
    fetched_at      timestamptz NOT NULL DEFAULT now()
);

-- /v2/Rail/Metro/Shape/{system} — partitioned by system (same system list as
-- raw_tdx.metro_station: TRTC/KRTC/KLRT/TYMC/NTMC). Geometry may be
-- MULTILINESTRING when a metro line branches.
CREATE TABLE IF NOT EXISTS raw_tdx.metro_shape (
    system          text,
    lineno          text,
    lineid          text,
    linename        jsonb,
    geometry        text,
    encodedpolyline text,
    updatetime      timestamptz,
    fetched_at      timestamptz NOT NULL DEFAULT now()
);

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
  tables text[] := ARRAY['tra_shape', 'thsr_shape', 'metro_shape'];
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
-- rail_shapes — env-schema table (public or staging, per target_schema).
-- system is '' (not NULL) for tra/thsr rows so the PK holds without a
-- nullable column; metro rows carry the real system code.
-- ============================================================================

CREATE TABLE IF NOT EXISTS rail_shapes (
    mode       text NOT NULL CHECK (mode IN ('tra', 'thsr', 'metro')),
    system     text NOT NULL DEFAULT '',
    line_id    text NOT NULL,
    line_name  jsonb,
    geom       geometry(Geometry, 4326) NOT NULL,
    updated_at timestamptz,
    PRIMARY KEY (mode, system, line_id)
);

CREATE INDEX IF NOT EXISTS idx_rail_shapes_geom ON rail_shapes USING GIST (geom);

COMMENT ON TABLE rail_shapes IS
    'TRA/THSR/metro line shapes loaded from raw_tdx.{tra,thsr,metro}_shape, used by the router to clip a MaaS transit section to the real line geometry (transitPath).';

COMMIT;
