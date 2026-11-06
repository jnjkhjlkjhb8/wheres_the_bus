-- PowerSync replicates from powersync-db since ADR-0028's step 2, so the main
-- cluster keeps no REPLICATION login: powersync_svc's logical walsender here
-- could still run BASE_BACKUP and copy every database (FDPL-137).
--
-- Applied by the operator as postgres through
-- `scripts/k3s-db-credentials.sh apply-superuser` (bus-infra) before this file
-- reaches main: bus_migrator can neither change a role's REPLICATION nor drop
-- a slot, and the publication belongs to postgres. Every statement is
-- idempotent; CI replay runs it once per schema.

DO $$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'current_schema() is NULL; set search_path before applying';
    END IF;
END
$$;

-- Revoke before terminating, so a terminated session cannot log straight back
-- in. The role stays (objects and grants still name it); PASSWORD NULL also
-- retires the password it shares with powersync-db.
ALTER ROLE powersync_svc NOLOGIN NOREPLICATION PASSWORD NULL;

-- NOLOGIN does not end open sessions; wait up to 5 s for each to exit.
SELECT pg_terminate_backend(pid, 5000) FROM pg_stat_activity WHERE usename = 'powersync_svc';

-- An inactive slot left behind holds WAL until max_slot_wal_keep_size.
SELECT pg_drop_replication_slot(slot_name)
FROM pg_replication_slots
WHERE slot_name LIKE 'powersync%' AND database = current_database() AND NOT active;

DROP PUBLICATION IF EXISTS powersync;

-- Fail loudly rather than leave a live session or a slot that was still in
-- use and so was skipped above.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE usename = 'powersync_svc') THEN
        RAISE EXCEPTION 'powersync_svc still has a session; rerun once it has exited';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_replication_slots
               WHERE slot_name LIKE 'powersync%' AND database = current_database()) THEN
        RAISE EXCEPTION 'a powersync replication slot remains on %; it was active', current_database();
    END IF;
END
$$;
