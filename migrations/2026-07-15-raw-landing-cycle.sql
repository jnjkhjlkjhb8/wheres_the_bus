BEGIN;

-- A cycle identifies one complete ingestor fan-out. Existing state is left
-- NULL deliberately: inventing a backfill could make independently refreshed
-- bus partitions appear correlated. The bus loader rejects NULL until a new
-- ingestor run verifies or replaces all eight city partitions.
ALTER TABLE raw_tdx.landing_state
    ADD COLUMN IF NOT EXISTS landing_cycle text;

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'raw_tdx.landing_state'::regclass
          AND conname = 'raw_landing_state_cycle_nonempty'
    ) THEN
        ALTER TABLE raw_tdx.landing_state
            ADD CONSTRAINT raw_landing_state_cycle_nonempty
            CHECK (landing_cycle IS NULL OR btrim(landing_cycle) <> '')
            NOT VALID;
    END IF;
END
$migration$;

COMMENT ON COLUMN raw_tdx.landing_state.landing_cycle IS
    'Shared identity for every full or verified-304 partition touched by one ingestor run; NULL is legacy/unverified and is rejected by correlated loaders.';

COMMIT;
