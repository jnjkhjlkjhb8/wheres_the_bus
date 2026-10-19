-- The powersync publication lists exactly the tables powersync/sync-rules.yaml
-- reads (FDPL-119). Earlier migrations added bus_static, search_vector and the
-- rail station tables for offline sync the app no longer does, and every one of
-- their nightly rewrites was streamed to PowerSync for nothing.
--
-- On the cluster, scripts/k3s-db-credentials.sh finish already narrowed the
-- publication as the superuser that owns it; the migrate Job (bus_migrator) is
-- not its owner, so there this file only checks. Replays run as a superuser and
-- narrow it. services/shared/dbgrants holds the publication to sync-rules.yaml.

DO $publication$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
        RETURN;
    END IF;
    IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
       OR pg_has_role(current_user, (SELECT pubowner FROM pg_publication WHERE pubname = 'powersync'), 'USAGE') THEN
        ALTER PUBLICATION powersync SET TABLE mrt_journey_matrix, mrt_schedule;
    ELSIF EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'powersync' AND tablename NOT IN ('mrt_journey_matrix', 'mrt_schedule')
    ) THEN
        RAISE EXCEPTION 'publication powersync lists tables sync-rules.yaml does not read'
            USING HINT = 'run: scripts/k3s-db-credentials.sh apply-superuser migrations/2026-10-09-powersync-publication-narrow.sql';
    END IF;
END
$publication$;
