-- Drops the Azure-era service logins that 2026-10-07-service-roles-k3s.sql
-- replaced (FDPL-119): router_svc, functions_svc, ingestor_svc, loader_svc.
-- powersync_svc is still in use and stays.
--
-- A cluster restored from the Azure dump never has these roles (pg_dump does
-- not carry roles), so on it this file does nothing and the migrate Job records
-- it. Where they do exist, dropping them needs a superuser: the Job runs as
-- bus_migrator, which cannot drop roles it did not create, and stops here with
-- the command to run instead. The file also refuses while any of them still has
-- a session open.

DO $contract$
DECLARE
    legacy constant text[] := ARRAY['router_svc', 'functions_svc', 'ingestor_svc', 'loader_svc'];
    present text[];
    r text;
BEGIN
    SELECT array_agg(rolname ORDER BY rolname) INTO present
    FROM pg_roles WHERE rolname = ANY (legacy);
    IF present IS NULL THEN
        RETURN;
    END IF;

    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'legacy logins % exist and only a superuser can drop them', present
            USING HINT = 'run: scripts/k3s-db-credentials.sh apply-superuser migrations/2026-10-09-legacy-db-roles-contract.sql';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE usename = ANY (present)) THEN
        RAISE EXCEPTION 'legacy logins still connected: %',
            (SELECT array_agg(DISTINCT usename) FROM pg_stat_activity WHERE usename = ANY (present));
    END IF;

    FOREACH r IN ARRAY present LOOP
        -- DROP OWNED revokes every grant in this database; the role owns no
        -- objects (bus_migrator owns them all since the service-roles migration).
        EXECUTE format('DROP OWNED BY %I', r);
        EXECUTE format('DROP ROLE %I', r);
    END LOOP;
END
$contract$;
