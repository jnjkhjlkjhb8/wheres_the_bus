-- migrations/baseline/0000-baseline.sql
--
-- Reconstructed pre-migrations-history schema baseline. See docs/adr/0010
-- for the decision this implements and migrations/README.md for how it is
-- used to bootstrap a new environment.
--
-- Why this file exists: migrations/*.sql is an INCREMENTAL delta on top of a
-- production schema that predates this directory's git history (the dated
-- files start 2026-06-14; the app existed before that, and nothing in this
-- repo's history created bus_stations, bus_subroutes, etc). This file is the
-- best-effort reconstruction of that missing genesis DDL, derived only from:
--   (a) SQL actually executed by services/functions and services/router
--       (INSERT/SELECT column lists, ON CONFLICT targets);
--   (b) migrations/*.sql — specifically, files that ALTER a table without
--       ever CREATE-ing it prove the table predates migrations/ and pin its
--       pre-migration column set (a column added later by a bare, unguarded
--       ALTER TABLE ... ADD COLUMN is deliberately NOT included here — see
--       the "columns deliberately omitted" note below each such table);
--   (c) docs/storage.md.
-- No column or constraint below is invented; where the source code does not
-- pin a detail precisely enough to be certain (documented per-table below as
-- TODO), that gap is called out rather than guessed.
--
-- Idempotent: every statement uses IF NOT EXISTS / a duplicate-object guard,
-- so applying this file against the real Azure schema (which already has
-- these objects, created out-of-band) is a no-op, and applying it against an
-- empty database creates the pre-migration baseline from which every dated
-- file in migrations/ replays cleanly.
--
-- Apply: this is step 1 of bootstrapping any environment — see
-- migrations/README.md "Bootstrap a new environment".

-- ============================================================================
-- Extensions
-- ============================================================================

-- Powers every geometry(Point,4326) column below (bus/bike/metro/rail
-- stations) and the geography casts in migrations/2026-07-03-db-health-indexes.sql.
CREATE EXTENSION IF NOT EXISTS postgis;

-- pgvector. Powers search_vector.embedding (docs/storage.md "vector" table)
-- and the HNSW index in migrations/2026-07-13-search-vector-hnsw.sql.
CREATE EXTENSION IF NOT EXISTS vector;

-- Trigram search. migrations/2026-06-14-perf-indexes.sql and
-- 2026-07-03-db-health-indexes.sql both build gin_trgm_ops indexes on
-- search_vector and assume this extension is already present; it is created
-- there too (IF NOT EXISTS), but search_vector itself needs to exist before
-- those indexes run, so this file is the natural place to also guarantee the
-- extension exists.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================================
-- Schemas
-- ============================================================================

-- ADR-0004: staging and production share one Azure PostgreSQL database,
-- isolated by PostgreSQL schema (PG_SCHEMA=staging vs PG_SCHEMA=public). No
-- tracked migration creates the `staging` schema itself (it is assumed to
-- already exist on Azure); this is the first place that gap is closed.
CREATE SCHEMA IF NOT EXISTS staging;

-- raw_tdx is created by migrations/2026-07-04-raw-tdx-schema.sql (ADR-0005),
-- not here — that migration is self-contained and already idempotent.

-- ============================================================================
-- Composite types
-- ============================================================================

-- bus_subroutes.stops is stop[]. Guarded the same way
-- services/functions/*_db_test.go provisions it (CREATE TYPE has no IF NOT
-- EXISTS form; catch duplicate_object instead).
DO $$ BEGIN
    CREATE TYPE stop AS (
        station_uid   text,
        stop_name     text,
        stop_sequence int,
        position_lon  float,
        position_lat  float
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================================
-- bus
-- ============================================================================

-- Columns deliberately omitted: `operators jsonb`. It is added by
-- migrations/2026-06-30-bus-operator.sql via a bare, unguarded
-- `ALTER TABLE bus_subroutes ADD COLUMN operators JSONB` (no IF NOT EXISTS).
-- Including it here would make that ALTER fail ("column already exists") on
-- a fresh replay, even though it runs clean against the real pre-2026-06-30
-- production table this baseline models.
CREATE TABLE IF NOT EXISTS bus_subroutes (
    sub_route_uid   text     NOT NULL,
    route_uid       text,
    direction       smallint NOT NULL,
    route_name      text,
    sub_route_name  text,
    city            text,
    depart          text,
    destin          text,
    geometry        text,
    stops           stop[],
    schedule        jsonb,
    updated_at      timestamptz NOT NULL DEFAULT NOW(),
    PRIMARY KEY (sub_route_uid, direction)
);

-- updated_at is added later by migrations/2026-06-30-static-updated-at.sql
-- (ADD COLUMN IF NOT EXISTS, safe either way); omitted here to match the
-- pre-migration column set that ALTER documents.
CREATE TABLE IF NOT EXISTS bus_stations (
    station_uid  text PRIMARY KEY,
    station_name text,
    city         text,
    position     geometry(Point, 4326)
);

-- updated_at is added later by migrations/2026-06-30-static-updated-at.sql;
-- omitted here for the same reason as bus_stations.
CREATE TABLE IF NOT EXISTS bus_station_stop_map (
    station_id    text,
    station_name  text,
    sub_route_uid text,
    route_name    text,
    direction     int,
    stop_uid      text,
    stop_sequence int,
    PRIMARY KEY (sub_route_uid, stop_uid, direction)
);

-- No natural-key uniqueness on purpose (docs/storage.md): circular routes
-- revisit the same stop within one trip and all such rows must survive.
-- migrations/2026-06-14-perf-indexes.sql later adds updated_at plus a
-- UNIQUE constraint, and migrations/2026-07-15-bus-static-contract-fixes.sql
-- drops that constraint again once the partition-replace contract was
-- confirmed — both are additive/idempotent against this shape.
CREATE TABLE IF NOT EXISTS bus_schedule (
    sub_route_uid                 text,
    direction                     smallint,
    type                          bool,
    tripid                        text,
    islowfloor                    bool,
    stopsequence                  smallint,
    "stop_uid/MinHeadwayMins"     text,
    "stop_name/MaxHeadwayMins"    text,
    "arrival_time/StartTime"      time,
    "departure_time/EndTime"      time,
    service_day                   smallint
);

CREATE TABLE IF NOT EXISTS bus_static (
    sub_route_name text,
    route_name     text,
    sub_route_uid  text PRIMARY KEY,
    route_uid      text,
    city           text,
    depart         text,
    destin         text,
    pb             bytea,
    updated_at     timestamptz NOT NULL DEFAULT NOW()
);

-- bus_operators is NOT created here. migrations/2026-06-30-bus-operator.sql
-- is itself the CREATE TABLE for it (bare, no IF NOT EXISTS) — it is not a
-- pre-migration baseline table, unlike everything else in this file.

-- ============================================================================
-- bike
-- ============================================================================

-- Column set and PRIMARY KEY (station_uid) derived from the
-- INSERT ... ON CONFLICT (station_uid) target in services/functions/bike.go.
CREATE TABLE IF NOT EXISTS bike_stations (
    station_uid  text PRIMARY KEY,
    station_id   text,
    name         text,
    capacity     int,
    service_type int,
    city         text,
    geom         geometry(Point, 4326),
    address      text,
    updated_at   timestamptz NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- mrt
-- ============================================================================

-- Column set and PRIMARY KEY (station_id, system) derived from the
-- INSERT ... ON CONFLICT (station_id, system) target in
-- services/functions/mrt.go (loadMrtStation).
CREATE TABLE IF NOT EXISTS mrt_station (
    station_id         text,
    system             text,
    name               text,
    city               text,
    stationposition    geometry(Point, 4326),
    bikeallowonholiday boolean,
    updated_at         timestamptz NOT NULL DEFAULT NOW(),
    PRIMARY KEY (station_id, system)
);

-- No PRIMARY KEY on purpose: loadMrtFirstlast (services/functions/mrt.go) is
-- partition-replace (DELETE by system, then INSERT DISTINCT ON the natural
-- key), matching the same pattern as bus_schedule. The natural-key UNIQUE
-- constraint is added later by migrations/2026-06-14-perf-indexes.sql.
CREATE TABLE IF NOT EXISTS mrt_schedule (
    station_id              text,
    lineid                  text,
    destinationstaionid     text,
    destinationstationname  text,
    firsttraintime          text,
    lasttraintime           text,
    serviceday               smallint,
    system                  text,
    created_at              timestamptz NOT NULL DEFAULT NOW(),
    trip_head_sign          text
);

-- ============================================================================
-- rail (TRA / THSR)
-- ============================================================================

-- updated_at is added later by migrations/2026-06-30-static-updated-at.sql;
-- omitted here for the same reason as bus_stations. PRIMARY KEY
-- (station_id) derived from the ON CONFLICT (station_id) target in
-- services/functions/rail.go (loadTraStation).
CREATE TABLE IF NOT EXISTS tra_stations (
    station_id text PRIMARY KEY,
    name       text,
    city       text,
    geom       geometry(Point, 4326)
);

-- Column set and PRIMARY KEY (station_id) derived from the
-- ON CONFLICT (station_id) target in services/functions/rail.go
-- (loadThsrStation).
CREATE TABLE IF NOT EXISTS thsr_stations (
    station_id  text PRIMARY KEY,
    name        text,
    city        text,
    geom        geometry(Point, 4326),
    stationcode text,
    updated_at  timestamptz NOT NULL DEFAULT NOW()
);

-- updated_at is added later by migrations/2026-06-30-static-updated-at.sql;
-- omitted here for the same reason as bus_stations. The UNIQUE constraint on
-- (origin_station_id, destination_station_id, ticket_type) is required by
-- the ON CONFLICT target in services/functions/rail.go (loadTraFare); no
-- tracked migration creates it, so it is asserted here as part of the
-- pre-migration baseline rather than invented.
CREATE TABLE IF NOT EXISTS tra_fares (
    origin_station_id      text NOT NULL,
    destination_station_id text NOT NULL,
    ticket_type             text NOT NULL,
    price                   int,
    CONSTRAINT tra_fares_natural_key
        UNIQUE (origin_station_id, destination_station_id, ticket_type)
);

-- updated_at is added later by migrations/2026-06-30-static-updated-at.sql;
-- omitted here for the same reason as tra_fares. UNIQUE constraint required
-- by the ON CONFLICT target in services/functions/rail.go (loadThsrFare).
CREATE TABLE IF NOT EXISTS thsr_fares (
    origin_station_id      text NOT NULL,
    destination_station_id text NOT NULL,
    ticket_type             smallint NOT NULL,
    fare_class              smallint NOT NULL,
    cabin_class             smallint NOT NULL,
    price                   int,
    CONSTRAINT thsr_fares_natural_key
        UNIQUE (origin_station_id, destination_station_id, ticket_type, fare_class, cabin_class)
);

-- Column set and the ON CONFLICT (train_date, trainno, stationid) unique
-- constraint derived from services/functions/rail.go (loadTraTimetable /
-- the tra_timetable insertSQL). Indexed further by
-- migrations/2026-06-14-perf-indexes.sql (idx_tra_timetable_station) and
-- migrations/2026-07-16-tra-fk-indexes.sql.
CREATE TABLE IF NOT EXISTS tra_timetable (
    train_date             date NOT NULL,
    trainno                text NOT NULL,
    direction               integer,
    starting_station_id    text NOT NULL,
    starting_station_name  text NOT NULL,
    ending_station_id      text NOT NULL,
    ending_station_name    text NOT NULL,
    train_type_id          text,
    train_type_code        text,
    train_type_name        text,
    tripline                integer,
    stopsequence            smallint,
    stationid               text,
    stationname             text,
    arrivaltime             time,
    departuretime           time,
    mask                    smallint,
    note                    text,
    updated_at              timestamptz,
    CONSTRAINT tra_timetable_natural_key
        UNIQUE (train_date, trainno, stationid)
);

-- Column set and the ON CONFLICT (train_date, trainno, stationid) unique
-- constraint derived from services/functions/rail.go (loadThsrTimetable).
CREATE TABLE IF NOT EXISTS thsr_timetable (
    train_date             date NOT NULL,
    trainno                text NOT NULL,
    direction               integer,
    starting_station_id    text NOT NULL,
    starting_station_name  text NOT NULL,
    ending_station_id      text NOT NULL,
    ending_station_name    text NOT NULL,
    stopsequence            smallint,
    stationid               text,
    stationname             text,
    arrivaltime             time,
    departuretime           time,
    note                    text,
    overnight                boolean,
    updated_at              timestamptz,
    CONSTRAINT thsr_timetable_natural_key
        UNIQUE (train_date, trainno, stationid)
);

-- ============================================================================
-- vector (offline/semantic search)
-- ============================================================================

-- Column set, embedding dimension, and unique key from docs/storage.md
-- ("vector" table: type/uid/name/city/depart/destin/geom/embedding
-- vector(1024)/updated_at; unique key (type, uid, city)) and the
-- INSERT ... ON CONFLICT (type, uid, city) target in
-- services/functions/vector.go (searchVectorUpsertSQL).
CREATE TABLE IF NOT EXISTS search_vector (
    type       text NOT NULL,
    uid        text NOT NULL,
    name       text,
    city       text,
    depart     text,
    destin     text,
    geom       geometry(Point, 4326),
    embedding  vector(1024),
    updated_at timestamptz NOT NULL DEFAULT NOW(),
    CONSTRAINT search_vector_natural_key
        UNIQUE (type, uid, city)
);

-- ============================================================================
-- PowerSync replication
-- ============================================================================

-- migrations/2026-07-14-powersync-publication-add-synced-tables.sql's header
-- comment states the `powersync` publication "only ever contained
-- bus_static" before that migration ran — i.e. bus_static is the one table
-- the publication's genesis DDL (not tracked anywhere in this repo) added.
-- A PostgreSQL PUBLICATION has no CREATE ... IF NOT EXISTS form and is
-- database-global (not schema-scoped), so guard it with a catalog check
-- instead; FOR TABLE resolves `bus_static` through the active search_path,
-- so applying this under search_path=staging targets staging.bus_static.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
        EXECUTE 'CREATE PUBLICATION powersync FOR TABLE bus_static';
    END IF;
END $$;

-- ============================================================================
-- TODO — genuinely underivable from code/migrations/docs
-- ============================================================================
-- The following are referenced by migrations/*.sql but this repo contains no
-- SQL, Go struct, or doc that pins their exact type/precision, so they are
-- NOT fabricated here. Both are index-only concerns (the base column already
-- exists per the derivations above); an operator with Azure schema access
-- should confirm these before relying on this baseline for a from-scratch
-- Azure rebuild:
--   * bus_station_groups, bus_station_group_members, mrt_journey_matrix,
--     bike_availability_history, bus_eta_prediction_error, pipeline_runs,
--     raw_tdx.landing_state and every raw_tdx.* table ARE fully created by
--     their own tracked migrations (2026-06-30-bus-station-groups.sql,
--     2026-06-16-mrt-journey-matrix.sql, 2026-07-06-*.sql,
--     2026-07-16-pipeline-runs.sql, 2026-07-04-raw-tdx-schema.sql,
--     2026-07-09-metro-s2s-transfer.sql) — no baseline entry needed.
--   * mrt_schedule.serviceday's exact bit width beyond "smallint bitmask,
--     bit 8 = NationalHolidays" (docs/storage.md) is not otherwise typed by
--     any source; smallint above matches the raw_tdx landing/decode path's
--     int2 usage but the live Azure column has not been confirmed.
