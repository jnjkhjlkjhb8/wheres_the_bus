-- O7.4 / review_results.md P1-15, P2-03: per-service least-privilege
-- PostgreSQL roles. Today every container (router, functions, ingestor,
-- loader, powersync) connects with the same DATABASE_URL/PS_*_URL
-- credential set the operator filled into env/<env>.env — a single leaked
-- or misused connection string reaches every table any service can reach.
-- This migration is an EXPAND-only, operator-optional step: it creates five
-- new roles and grants them schema-scoped privileges. It changes nothing
-- about how any existing connection behaves — DATABASE_URL, PS_DATABASE_URL,
-- and PS_SOURCE_DATABASE_URL keep working exactly as configured today.
-- Pointing a service's connection string at its new _svc role (and dropping
-- the shared credential from its allowlisted env, see scripts/env-
-- allowlists/) is a separate, later operator action once real passwords are
-- set (see bottom).
--
-- Roles created (LOGIN, PASSWORD NULL -- i.e. password login is disabled
-- until the operator sets a real one; no credential is stored by this
-- file):
--   router_svc     - SELECT/INSERT/UPDATE/DELETE on the target schema.
--                     Router is not read-only: services/router/
--                     firebase_store.go writes firebase_device,
--                     firebase_route_subscription, and
--                     firebase_arrival_reminder directly (UpsertDevice /
--                     SetRouteSubscription / reminder dispatch). No access
--                     to raw_tdx -- router never reads it.
--   functions_svc  - SELECT/INSERT/UPDATE/DELETE on the target schema
--                     (realtime ETA writes, notification dispatch store,
--                     the legacy prod path's boot-time static load) plus
--                     SELECT on raw_tdx (rawSourcePool falls back to the
--                     target-schema pool itself when RAW_DATABASE_URL is
--                     unset, i.e. the common single-cluster case, so this
--                     process is the one that actually issues the raw_tdx
--                     read in that configuration).
--   ingestor_svc   - INSERT/SELECT on raw_tdx only. The 03:00 landing job
--                     (services/functions/ingestor.go) never opens a
--                     connection scoped to the target schema.
--   loader_svc     - SELECT/INSERT/UPDATE/DELETE on the target schema (the
--                     03:30 transform's write side) plus SELECT on raw_tdx
--                     (its read-only source; the loader never writes
--                     raw_tdx).
--   powersync_svc  - REPLICATION (logical replication requires this role
--                     attribute, not a GRANT) + SELECT on the target schema
--                     for PS_SOURCE_DATABASE_URL. PS_DATABASE_URL --
--                     PowerSync's own bucket-storage database -- is a
--                     separate database entirely; this migration, scoped to
--                     the app database, does not and cannot reach it.
--
-- Grants are schema-level (ALL TABLES/SEQUENCES IN SCHEMA + ALTER DEFAULT
-- PRIVILEGES for whatever the applying role creates next), not enumerated
-- per table -- O7.4 calls this the practical granularity; per-table GRANTs
-- for a schema with dozens of tables would need a follow-up migration every
-- time a table is added, which is its own maintenance hazard.
--
-- Apply with (target_schema=staging for staging, public for prod):
--   PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--       -v target_schema=staging -f migrations/2026-07-17-db-service-roles.sql
-- (target_schema=public with search_path=public for prod.)
--
-- After applying, set real passwords before pointing any service at these
-- roles (roles are cluster-wide, so run this once per Azure server, not per
-- schema):
--   ALTER ROLE router_svc     WITH PASSWORD '...';
--   ALTER ROLE functions_svc  WITH PASSWORD '...';
--   ALTER ROLE ingestor_svc   WITH PASSWORD '...';
--   ALTER ROLE loader_svc     WITH PASSWORD '...';
--   ALTER ROLE powersync_svc  WITH PASSWORD '...';

\set ON_ERROR_STOP on

\if :{?target_schema}
\else
    \set target_schema _unset_
\endif

-- psql does not interpolate :variables inside dollar-quoted DO bodies, so
-- the value is passed through a session GUC (same pattern as
-- 2026-07-16-pipeline-runs.sql / 2026-07-16-search-vector-hnsw-dedupe.sql).
-- ON_ERROR_STOP turns the RAISE into a nonzero psql exit before anything is
-- created.
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

-- Role creation is cluster-wide (CREATE ROLE has no schema scope), so it
-- must be idempotent across repeated applies against different schemas on
-- the same server (e.g. once with target_schema=public, once with
-- target_schema=staging) without erroring on "role already exists".
DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'router_svc') THEN
        CREATE ROLE router_svc LOGIN PASSWORD NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'functions_svc') THEN
        CREATE ROLE functions_svc LOGIN PASSWORD NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ingestor_svc') THEN
        CREATE ROLE ingestor_svc LOGIN PASSWORD NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loader_svc') THEN
        CREATE ROLE loader_svc LOGIN PASSWORD NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powersync_svc') THEN
        CREATE ROLE powersync_svc LOGIN PASSWORD NULL REPLICATION;
    ELSE
        -- REPLICATION may have been granted after the role already existed
        -- from an earlier apply of this same file; ALTER is idempotent.
        ALTER ROLE powersync_svc REPLICATION;
    END IF;
END
$roles$;

-- ---------------------------------------------------------------------
-- Target-schema grants (public or staging, per :target_schema above).
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA :"target_schema" TO router_svc, functions_svc, loader_svc, powersync_svc;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"target_schema" TO router_svc;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"target_schema" TO router_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"target_schema" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO router_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"target_schema" GRANT USAGE, SELECT ON SEQUENCES TO router_svc;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"target_schema" TO functions_svc;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"target_schema" TO functions_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"target_schema" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO functions_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"target_schema" GRANT USAGE, SELECT ON SEQUENCES TO functions_svc;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"target_schema" TO loader_svc;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"target_schema" TO loader_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"target_schema" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO loader_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"target_schema" GRANT USAGE, SELECT ON SEQUENCES TO loader_svc;

-- powersync_svc: read-only on the target schema. Logical replication reads
-- the WAL directly (that's what the REPLICATION role attribute is for), but
-- the initial sync/backfill and PowerSync's own schema introspection go
-- through ordinary SELECT.
GRANT SELECT ON ALL TABLES IN SCHEMA :"target_schema" TO powersync_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA :"target_schema" GRANT SELECT ON TABLES TO powersync_svc;

-- ---------------------------------------------------------------------
-- raw_tdx grants — independent of :target_schema; raw_tdx is the one
-- schema shared across every environment (AGENTS.md), not per-PG_SCHEMA.
-- Applying this file once for public and again for staging repeats these
-- statements harmlessly (GRANT is idempotent).
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA raw_tdx TO functions_svc, ingestor_svc, loader_svc;

GRANT SELECT ON ALL TABLES IN SCHEMA raw_tdx TO functions_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_tdx GRANT SELECT ON TABLES TO functions_svc;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA raw_tdx TO ingestor_svc;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA raw_tdx TO ingestor_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_tdx GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ingestor_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_tdx GRANT USAGE, SELECT ON SEQUENCES TO ingestor_svc;

GRANT SELECT ON ALL TABLES IN SCHEMA raw_tdx TO loader_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_tdx GRANT SELECT ON TABLES TO loader_svc;
