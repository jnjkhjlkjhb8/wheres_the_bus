-- Rider-to-ops feedback. A report is a thread with one message in it; the
-- split exists from the start because ops replies are the next message on the
-- same thread, and growing into that shape later would mean moving live rows
-- on the Azure box rather than adding a table beside them.
--
-- Both tables live in the environment's own PG_SCHEMA, not raw_tdx: this is
-- app-owned data, not landed TDX. The same forgotten-search_path hazard as
-- every other transform target applies, so the guard requires the operator to
-- name the intended schema explicitly. Apply with:
--
--   PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--       -v target_schema=staging -f migrations/2026-07-27-feedback.sql
--
-- (target_schema=public with search_path=public for prod.)
--
-- No GRANTs here: 2026-07-17-db-service-roles.sql set ALTER DEFAULT PRIVILEGES
-- on this schema, so router_svc picks up SELECT/INSERT/UPDATE/DELETE on both
-- tables as they are created.

\set ON_ERROR_STOP on

\if :{?target_schema}
\else
    \set target_schema _unset_
\endif

-- psql does not interpolate :variables inside dollar-quoted DO bodies, so the
-- value is passed through a session GUC (same pattern as
-- 2026-07-16-pipeline-runs.sql). ON_ERROR_STOP turns the RAISE into a nonzero
-- psql exit before anything is created.
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

-- install_id is the same anonymous installation identity firebase_device keys
-- on, but deliberately not a foreign key to it: a rider who has turned push
-- off, or whose device row was cleaned up, must still be able to report a
-- problem. category is constrained here rather than only in Go so a future
-- client release cannot quietly widen the ops-side grouping.
CREATE TABLE IF NOT EXISTS feedback_thread (
    id          uuid        PRIMARY KEY,
    install_id  text        NOT NULL CHECK (install_id <> ''),
    category    text        NOT NULL CHECK (category IN ('route_data', 'eta', 'crash', 'suggestion')),
    diagnostics jsonb       NOT NULL DEFAULT '{}'::jsonb,
    status      text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE feedback_thread IS
    'One rider-submitted report: its category, the app diagnostics captured at submit time, and whether ops have finished with it.';

-- Serves the per-install daily submission quota, which counts this
-- installation's threads inside a trailing window on every submit.
CREATE INDEX IF NOT EXISTS feedback_thread_install_recent_idx
    ON feedback_thread (install_id, created_at DESC);

-- Serves the ops triage read: the open threads, newest first. Partial so the
-- index stays the size of the backlog rather than the archive.
CREATE INDEX IF NOT EXISTS feedback_thread_open_idx
    ON feedback_thread (created_at DESC)
    WHERE status = 'open';

-- author is text rather than a boolean because 'ops' rows are written by hand
-- in psql; a column whose value reads as itself is worth more than two bytes.
CREATE TABLE IF NOT EXISTS feedback_message (
    id         uuid        PRIMARY KEY,
    thread_id  uuid        NOT NULL REFERENCES feedback_thread (id) ON DELETE CASCADE,
    author     text        NOT NULL CHECK (author IN ('user', 'ops')),
    body       text        NOT NULL CHECK (body <> ''),
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE feedback_message IS
    'One message on a feedback thread, from the rider who opened it or from ops replying.';

CREATE INDEX IF NOT EXISTS feedback_message_thread_idx
    ON feedback_message (thread_id, created_at);

COMMIT;
