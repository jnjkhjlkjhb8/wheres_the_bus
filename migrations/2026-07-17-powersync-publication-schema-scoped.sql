-- P0-05 remediation (review_results.md): schema-scoped replacement for
-- 2026-07-14-powersync-publication-add-synced-tables.sql, which hardcoded
-- `schemaname = 'public'` / `public.%I`. Staging and production share one
-- Azure PostgreSQL database, differentiated only by `PG_SCHEMA`
-- (`staging` vs `public` — see AGENTS.md's environment table and
-- docs/adr/ ADR-0004 schema isolation). A migration that hardcodes
-- `public` and gets applied with `PGOPTIONS="-c search_path=staging"`
-- silently mutates PRODUCTION's publication/replica-identity instead of
-- staging's — see docs/runbooks/2026-07-17-release-freeze-and-secret-incident.md
-- for the audit that found this.
--
-- This migration targets `current_schema()` instead: every `ALTER
-- PUBLICATION`/`ALTER TABLE` below is schema-qualified with
-- `format('%I.%I', current_schema(), tablename)`, and the DO block at the
-- top fails fast if `current_schema()` is not one of the two schemas this
-- repo actually uses (`public`, `staging`), so a missing/wrong
-- `search_path` aborts before touching anything instead of silently
-- landing in the wrong schema.
--
-- Table list: the three originally published by the 2026-07-14 migration
-- (`mrt_journey_matrix`, `mrt_schedule`, `bus_station_groups` is
-- intentionally NOT re-added here — it was never in the app's PowerSync
-- Schema/sync-rules and stays out of scope for this migration) plus the
-- ones the app schema now declares (O2.1 remediation, see
-- app/lib/core/powersync/powersync_service.dart and docs/storage.md
-- "PowerSync（離線鏡像）"): `search_vector`, `tra_stations`, `thsr_stations`.
-- `mrt_station` is excluded on purpose — the app's PowerSync schema and
-- sync-rules.yaml were confirmed to not sync it (see
-- powersync_service.dart's schema comment: no repository queries it under
-- the corrected name), so publishing it would be dead replication traffic.
--
-- Assumption (uncertain — flag if wrong): this repo uses a single
-- publication name, `powersync`, shared across environments — confirmed by
-- the 2026-07-14 migration and by powersync/config.yaml's single
-- `PS_SOURCE_DATABASE_URL` connection per env, each scoped by
-- `options=-c search_path=<env schema>` (see env/*.env.example). Because a
-- Postgres publication's table membership is always schema-qualified
-- (`schema.table`), one publication safely holds both `public.mrt_schedule`
-- and `staging.mrt_schedule` as distinct members — this migration adds only
-- the member for the schema it is run against.
--
-- Idempotent: skips any (schema, table) pair already in the publication or
-- already carrying a primary key / explicit replica identity, exactly like
-- the file it supersedes. Safe to re-run.
--
-- Apply (operator action — agents cannot reach Azure; see AGENTS.md):
--   staging: PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/2026-07-17-powersync-publication-schema-scoped.sql
--   prod:    PGOPTIONS="-c search_path=public"  psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/2026-07-17-powersync-publication-schema-scoped.sql
-- After applying, restart the PowerSync service so it snapshots the newly
-- added tables: docker compose restart powersync

DO $$
DECLARE
  target_schema text := current_schema();
  t text;
  tables text[] := ARRAY[
    'mrt_journey_matrix',
    'mrt_schedule',
    'search_vector',
    'tra_stations',
    'thsr_stations'
  ];
BEGIN
  IF target_schema IS NULL OR target_schema NOT IN ('public', 'staging') THEN
    RAISE EXCEPTION
      'current_schema() is %; expected ''public'' or ''staging''. Set '
      'PGOPTIONS="-c search_path=<schema>" before applying (see this '
      'file''s header comment).',
      coalesce(target_schema, '<none>');
  END IF;

  FOREACH t IN ARRAY tables LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'powersync'
        AND schemaname = target_schema
        AND tablename = t
    ) THEN
      EXECUTE format(
        'ALTER PUBLICATION powersync ADD TABLE %I.%I',
        target_schema, t
      );
    END IF;

    -- PowerSync needs a replica identity to replicate UPDATE/DELETE. A
    -- primary key already satisfies this (REPLICA IDENTITY DEFAULT); set
    -- FULL on any table without one so the daily loader's upserts/deletes
    -- propagate.
    IF NOT EXISTS (
      SELECT 1 FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = target_schema AND c.relname = t AND i.indisprimary
    ) THEN
      EXECUTE format('ALTER TABLE %I.%I REPLICA IDENTITY FULL', target_schema, t);
    END IF;
  END LOOP;
END;
$$;
