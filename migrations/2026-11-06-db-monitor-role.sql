-- db_monitor is the db-alerts CronJob's login (FDPL-136). It reads only
-- pg_replication_slots and pg_roles, which every role may read, so it gets no
-- grants: with no REPLICATION login left on this cluster (ADR-0028), any slot
-- or replication-capable role it finds is an alert.
--
-- Applied by the operator as postgres through
-- `scripts/k3s-db-credentials.sh apply-superuser` (bus-infra) before this file
-- reaches main: bus_migrator cannot create roles. The password is set by
-- `k3s-db-credentials.sh passwords`.

DO $$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'current_schema() is NULL; set search_path before applying';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_monitor') THEN
        CREATE ROLE db_monitor LOGIN;
    END IF;
END
$$;
