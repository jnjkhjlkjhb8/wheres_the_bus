-- Supersedes the unconditional
-- `DROP INDEX CONCURRENTLY IF EXISTS bus_schedule_idx_unique;` in
-- 2026-07-03-db-health-indexes.sql. That file is already applied and, per
-- AGENTS.md, historical migrations are never edited — this file corrects
-- its effect going forward instead of rewriting history.
--
-- The live schema audit found that drop was a false positive: despite its
-- name, bus_schedule_idx_unique was never a UNIQUE index or constraint —
-- no CREATE UNIQUE INDEX / ADD CONSTRAINT ... UNIQUE targeting that name
-- exists anywhere in this repo's migration history. It was a plain,
-- high-scan btree supporting natural-key lookups, dropped on 2026-07-03
-- solely because its name contained the substring "unique" and was assumed
-- redundant with the bus_schedule_natural_key UNIQUE constraint added the
-- same day (2026-06-14-perf-indexes.sql).
--
-- That assumption doesn't hold. bus_schedule_natural_key was itself
-- dropped by 2026-07-15-bus-static-contract-fixes.sql, because circular bus
-- routes legitimately produce duplicate natural keys (the loader treats
-- bus_schedule as partition-replace, not upsert, precisely because of
-- this). A true UNIQUE index over those columns cannot exist on this
-- table. This migration restores the lost scan performance with a
-- NON-unique index over the same key columns, and asserts at apply time
-- that bus_schedule still allows duplicates on those columns.
--
-- Do not "fix" this by adding UNIQUE, and no future migration should drop
-- bus_schedule_scan_idx by pattern-matching its name against "unique" —
-- bus_schedule intentionally keeps circular-route duplicates.
--
-- CONCURRENTLY must run outside a transaction block. Idempotent
-- (IF NOT EXISTS; the verification blocks are read-only).

\set ON_ERROR_STOP on

DO $schema_check$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'search_path must resolve a target schema; set PGOPTIONS=''-c search_path=<schema>'' before applying';
    END IF;
END
$schema_check$;

CREATE INDEX CONCURRENTLY IF NOT EXISTS bus_schedule_scan_idx
    ON bus_schedule (sub_route_uid, direction, type, service_day, tripid, "stop_uid/MinHeadwayMins");

-- Verify: the recreated index exists and is not unique.
DO $verify_index$
DECLARE
    is_unique boolean;
BEGIN
    SELECT i.indisunique INTO is_unique
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
     WHERE c.relname = 'bus_schedule_scan_idx'
       AND i.indrelid = 'bus_schedule'::regclass;

    IF is_unique IS NULL THEN
        RAISE EXCEPTION 'bus_schedule_scan_idx was not created';
    END IF;
    IF is_unique THEN
        RAISE EXCEPTION 'bus_schedule_scan_idx must stay non-unique: bus_schedule intentionally contains circular-route duplicate natural keys';
    END IF;
END
$verify_index$;

-- Verify: no UNIQUE constraint/index has crept back onto bus_schedule.
DO $verify_no_unique_constraint$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM pg_constraint c
         WHERE c.conrelid = 'bus_schedule'::regclass
           AND c.contype = 'u'
    ) THEN
        RAISE EXCEPTION 'bus_schedule must not carry a UNIQUE constraint; circular routes require duplicate natural keys (see 2026-07-15-bus-static-contract-fixes.sql)';
    END IF;
END
$verify_no_unique_constraint$;
