-- Durable completion marker for the nightly static pipeline, replacing pure
-- clock coordination between the loader (03:30, its own container) and the
-- legacy prod process's changetovector (03:45) and computeTravelAvg (04:00).
-- Each stage upserts its own row only after a fully successful run; the next
-- stage polls for it instead of assuming the previous stage finished in time.
--
-- Lives in the environment's own PG_SCHEMA (like every other transform target
-- table, not raw_tdx). Because a forgotten search_path would silently land
-- this table in public — exactly the schema prod reads — the guard requires
-- the operator to name the intended schema explicitly (psql -v) and asserts
-- the session's search_path actually resolves to it. Apply with:
--
--   PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--       -v target_schema=staging -f migrations/2026-07-16-pipeline-runs.sql
--
-- (target_schema=public with search_path=public for prod.)

\set ON_ERROR_STOP on

\if :{?target_schema}
\else
    \set target_schema _unset_
\endif

-- psql does not interpolate :variables inside dollar-quoted DO bodies, so
-- the value is passed through a session GUC (same pattern as
-- 2026-07-16-search-vector-hnsw-dedupe.sql). ON_ERROR_STOP turns the RAISE
-- into a nonzero psql exit before anything is created.
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

CREATE TABLE IF NOT EXISTS pipeline_runs (
    job          text        NOT NULL CHECK (job <> ''),
    run_date     date        NOT NULL,
    completed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (job, run_date)
);

COMMENT ON TABLE pipeline_runs IS
    'Durable per-day completion marker for one nightly static pipeline stage (job), upserted only on full success; downstream stages poll it instead of coordinating by clock.';

COMMIT;
