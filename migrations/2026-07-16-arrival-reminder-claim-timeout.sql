-- Adds firebase_arrival_reminder.claimed_at so a crashed dispatcher cannot
-- strand a reminder in 'sending' forever. claim() stamps this on every
-- 'pending'→'sending' transition; the reminder sweeps and claim() treat a
-- 'sending' row whose claimed_at is older than the reclaim timeout (or NULL —
-- a row stuck from before this column existed) as claimable again, so the
-- reminder is retried instead of silently never delivered. release() clears
-- it when a failed send returns the row to 'pending'.
--
-- Deploy ordering: apply this migration BEFORE deploying the binary that
-- references claimed_at — the new claim/sweep SQL fails on a missing column
-- (breaking all reminder delivery loudly until applied), while migration-first
-- is safe because the old binary simply ignores the nullable column.
--
-- Lives in the environment's own PG_SCHEMA. The guard requires the operator
-- to name the intended schema explicitly (psql -v) and asserts the session's
-- search_path actually resolves to it. Apply with:
--
--   PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--       -v target_schema=staging -f migrations/2026-07-16-arrival-reminder-claim-timeout.sql
--
-- (target_schema=public with search_path=public for prod.)

\set ON_ERROR_STOP on

\if :{?target_schema}
\else
    \set target_schema _unset_
\endif

-- psql does not interpolate :variables inside dollar-quoted DO bodies, so
-- the value is passed through a session GUC (same pattern as
-- 2026-07-16-pipeline-runs.sql). ON_ERROR_STOP turns the RAISE into a
-- nonzero psql exit before anything is changed.
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

-- Nullable on purpose: NULL means "never claimed under this scheme", which
-- includes rows already stuck in 'sending' when this migration lands — the
-- reclaim predicate treats those as immediately claimable.
ALTER TABLE firebase_arrival_reminder
    ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

COMMENT ON COLUMN firebase_arrival_reminder.claimed_at IS
    'When the row last entered ''sending''; a ''sending'' row whose claimed_at is NULL or older than the dispatcher''s reclaim timeout is claimable again (crash recovery).';

COMMIT;
