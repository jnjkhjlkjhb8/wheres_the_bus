-- Per-service logins for the k3s split (ADR-0026, ADR-0027, FDPL-106).
--
-- Expand-only. The 2026-07-17 roles (router_svc, functions_svc, ingestor_svc,
-- loader_svc) are left in place and are removed by a later -contract file
-- once nothing connects with them. powersync_svc is reused unchanged.
--
-- Write ownership (who may INSERT/UPDATE/DELETE):
--   rider_svc     firebase_device, firebase_route_subscription,
--                 firebase_arrival_reminder, feedback_thread, feedback_message.
--                 No other login can read these tables.
--   pipeline_svc  every other table in public, and all of raw_tdx
--                 (including TRUNCATE, which raw landing uses).
--   api_svc, realtime_svc
--                 read-only: SELECT on public except the rider tables.
--   bus_migrator  owns every table and applies migrations (the migrate Job).
--                 It is not a superuser and has no BYPASSRLS.
--
-- There are deliberately no ALTER DEFAULT PRIVILEGES: a migration that adds a
-- table must grant it explicitly, and the grant coverage test
-- (services/shared/dbgrants) fails until it does.
--
-- Apply once, as a superuser, on the new cluster. It runs before bus_migrator
-- exists as an owner, so the migrate Job cannot apply it. Passwords are set
-- separately (LOGIN with PASSWORD NULL refuses password auth until then):
--   ALTER ROLE bus_migrator WITH PASSWORD '...';   -- and each *_svc role

BEGIN;

DO $roles$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['bus_migrator', 'api_svc', 'realtime_svc', 'rider_svc', 'pipeline_svc'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD NULL', r);
        END IF;
    END LOOP;
END
$roles$;

GRANT USAGE, CREATE ON SCHEMA public, raw_tdx TO bus_migrator;
GRANT USAGE ON SCHEMA public TO api_svc, realtime_svc, rider_svc, pipeline_svc;
GRANT USAGE ON SCHEMA raw_tdx TO pipeline_svc;

DO $grants$
DECLARE
    rider_tables constant text[] := ARRAY[
        'firebase_device', 'firebase_route_subscription', 'firebase_arrival_reminder',
        'feedback_thread', 'feedback_message'];
    t record;
    seq record;
    writer text;
BEGIN
    FOR t IN
        SELECT schemaname, tablename FROM pg_tables
        WHERE schemaname IN ('public', 'raw_tdx')
          -- PostGIS owns spatial_ref_sys; it is not application data.
          AND NOT (schemaname = 'public' AND tablename IN ('schema_migrations', 'spatial_ref_sys'))
    LOOP
        EXECUTE format('ALTER TABLE %I.%I OWNER TO bus_migrator', t.schemaname, t.tablename);

        IF t.schemaname = 'raw_tdx' THEN
            EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON %I.%I TO pipeline_svc',
                t.schemaname, t.tablename);
            writer := 'pipeline_svc';
        ELSIF t.tablename = ANY (rider_tables) THEN
            EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO rider_svc',
                t.schemaname, t.tablename);
            writer := 'rider_svc';
        ELSE
            EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO pipeline_svc',
                t.schemaname, t.tablename);
            EXECUTE format('GRANT SELECT ON %I.%I TO api_svc, realtime_svc, rider_svc',
                t.schemaname, t.tablename);
            writer := 'pipeline_svc';
        END IF;

        -- Sequences behind serial/identity columns follow their table's writer.
        FOR seq IN
            SELECT s.relname AS name
            FROM pg_depend d
            JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
            JOIN pg_class c ON c.oid = d.refobjid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = t.schemaname AND c.relname = t.tablename
        LOOP
            EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO bus_migrator', t.schemaname, seq.name);
            EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %I.%I TO %I', t.schemaname, seq.name, writer);
        END LOOP;
    END LOOP;
END
$grants$;

ALTER TABLE IF EXISTS public.schema_migrations OWNER TO bus_migrator;

COMMIT;
