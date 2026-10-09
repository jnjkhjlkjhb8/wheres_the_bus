-- REPLAY: skip
-- WARNING (2026-07-17, P0-05 remediation, review_results.md): DO NOT RE-RUN
-- this file as-is. It hardcodes `schemaname = 'public'` / `public.%I`, so
-- running it against staging (PG_SCHEMA=staging, same Azure database as
-- prod — see AGENTS.md) silently touches PRODUCTION's `public` schema
-- publication/replica-identity instead of staging's tables. It is kept
-- unmodified here because it may already have been applied to prod and its
-- SQL must not change retroactively (see migrations/README.md: "Do not
-- edit a migration after it has been applied").
--
-- Superseded by migrations/2026-07-17-powersync-publication-schema-scoped.sql,
-- which targets `current_schema()` instead of a hardcoded schema name, and
-- also covers the tables added since (search_vector, plus the two rail
-- station tables already listed below). Apply that file instead — for both
-- envs — going forward.
--
-- The `powersync` publication only ever contained `bus_static`, so PowerSync
-- replicated nothing else. Every other table the sync rules read
-- (powersync/sync-rules.yaml) — the metro fare/time matrix, station lists,
-- schedules, bus stop groups — never reached the device, so the app's local
-- mirrors stayed empty and the metro map showed no fares or travel times.
-- PowerSync replicates ONLY tables in its Postgres publication; add the rest.
--
-- Idempotent: skips tables already published. After applying, restart the
-- PowerSync service so it snapshots the newly added tables:
--   docker compose restart powersync

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'mrt_journey_matrix',
    'mrt_station',
    'mrt_schedule',
    'bus_station_groups',
    'tra_stations',
    'thsr_stations'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'powersync' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION powersync ADD TABLE public.%I', t);
    END IF;

    -- PowerSync needs a replica identity to replicate UPDATE/DELETE. A primary
    -- key already satisfies this (REPLICA IDENTITY DEFAULT); set FULL on any
    -- table without one so the daily loader's upserts/deletes propagate.
    IF NOT EXISTS (
      SELECT 1 FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = t AND i.indisprimary
    ) THEN
      EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY FULL', t);
    END IF;
  END LOOP;
END;
$$;
