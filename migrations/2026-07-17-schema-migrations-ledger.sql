-- Adds the schema_migrations ledger table (ADR-0010): one row per applied
-- migration file, written only by scripts/apply-migration.sh. Not written
-- by any application code and not read by services/router or
-- services/functions — this is an operator/tooling table.
--
-- Lives in the environment's own PG_SCHEMA (like every other transform
-- target table, not raw_tdx) so staging and production each track their own
-- apply history. The guard requires the operator to name the intended
-- schema explicitly (psql -v) and asserts the session's search_path
-- actually resolves to it, matching the pattern established by
-- 2026-07-16-pipeline-runs.sql / 2026-07-16-arrival-reminder-claim-timeout.sql.
--
--   PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--       -v target_schema=staging -f migrations/2026-07-17-schema-migrations-ledger.sql
--
-- (target_schema=public with search_path=public for prod.)

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

CREATE TABLE IF NOT EXISTS schema_migrations (
    filename    text        PRIMARY KEY,
    sha256      text        NOT NULL CHECK (sha256 <> ''),
    applied_at  timestamptz NOT NULL DEFAULT now(),
    applied_by  text        NOT NULL CHECK (applied_by <> '')
);

COMMENT ON TABLE schema_migrations IS
    'Apply-history ledger written only by scripts/apply-migration.sh (ADR-0010); not a golang-migrate version table, no runner reads it.';

COMMIT;
