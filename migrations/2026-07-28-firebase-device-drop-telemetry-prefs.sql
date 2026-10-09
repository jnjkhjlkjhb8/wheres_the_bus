-- Drops the three telemetry preference columns from firebase_device.
--
-- Analytics, Crashlytics and Performance collection are no longer a rider
-- choice: the settings screen keeps only the push switch and the app turns all
-- three on unconditionally, so these columns can only ever hold TRUE. They also
-- left DevicePrefs, so nothing reads or writes them any more.
--
-- ORDERING: apply this only AFTER the router that stopped naming these columns
-- is live. They are NOT NULL, and the previous router's UpsertDevice inserts
-- them explicitly — dropping them first makes every device registration fail
-- until the new build lands.
--
-- Apply with:
--
--   PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--       -v target_schema=staging -f migrations/2026-07-28-firebase-device-drop-telemetry-prefs.sql
--
-- (target_schema=public with search_path=public for prod.)

\set ON_ERROR_STOP on

\if :{?target_schema}
\else
    \set target_schema _unset_
\endif

-- psql does not interpolate :variables inside dollar-quoted DO bodies, so the
-- value is passed through a session GUC. ON_ERROR_STOP turns the RAISE into a
-- nonzero psql exit before anything is dropped.
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

ALTER TABLE firebase_device
    DROP COLUMN IF EXISTS analytics_enabled,
    DROP COLUMN IF EXISTS crashlytics_enabled,
    DROP COLUMN IF EXISTS performance_enabled;

COMMIT;
