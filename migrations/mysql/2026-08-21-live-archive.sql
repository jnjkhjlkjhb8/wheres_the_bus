-- 2026-08-21-live-archive.sql — MySQL, NOT PostgreSQL.
--
-- Apply by hand on the archive host, like every file in this directory:
--
--   mysql bus < migrations/mysql/2026-08-21-live-archive.sql
--
-- The realtime streams' upstream payloads, stored verbatim (ADR-0023, FDPL-98).
-- Everything this system holds about a past moment is currently a parsed
-- derivative -- bus_eta_history and bus_stop_event are shaped for the ETA model,
-- not for reconstructing what upstream said. These tables are the latter:
-- gzipped response bodies, exactly as served, so a day whose parser had a bug
-- can still be read correctly afterwards.
--
-- Why not raw_tdx_archive: the retention policies are opposites. That table is
-- never pruned and is not partitioned; these are pruned by DROP PARTITION, and
-- retrofitting partitions there would rewrite the table holding the only copy of
-- the static payloads. The code is shared (archiveInsert, archiveUTC, the
-- dataset/partition_val/payload convention); the table is not.
--
-- WHY TWO TABLES. Retention is per stream (bus 90 days, everything else
-- indefinite) and pruning is DROP PARTITION, which takes every dataset in the
-- partition with it. A partition cannot be dropped for one dataset and kept for
-- another, so the retention class has to be the table. live_archive_bus is the
-- 90-day class; live_archive is the permanent one.
--
-- Conventions follow 2026-07-30-history-archive.sql: UTC DATETIMEs normalized in
-- Go by archiveUTC, rows appended through the same background flusher.
--
-- No unique key on either. Realtime has no version: every tick is new content,
-- so raw_tdx_archive's uq_version dedup would never fire (an ETA changes every
-- second) while still costing an index write per row.

-- Kept indefinitely: live_mrt (Metro Taipei SOAP -- the only source of per-car
-- congestion), live_mrt_liveboard, live_tra, live_thsr, live_mqtt.
-- Measured volume is small; see docs/archive.md for the estimates.
CREATE TABLE IF NOT EXISTS live_archive (
  id            BIGINT      NOT NULL AUTO_INCREMENT,
  dataset       VARCHAR(64) NOT NULL,             -- 'live_mrt', 'live_tra', 'live_mqtt', ...
  partition_val VARCHAR(64) NOT NULL DEFAULT '',  -- system / SOAP method / MQTT topic
  recorded_at   DATETIME    NOT NULL,             -- when this system received it, UTC
  payload       LONGBLOB    NOT NULL,             -- gzipped response body, verbatim
  PRIMARY KEY (id, recorded_at),
  KEY idx_stream (dataset, partition_val, recorded_at)
) ENGINE=InnoDB
PARTITION BY RANGE (TO_DAYS(recorded_at)) (
  PARTITION p2026_08 VALUES LESS THAN (TO_DAYS('2026-09-01')),
  PARTITION p_max    VALUES LESS THAN MAXVALUE
);

-- Kept 90 days: live_bus_eta, live_bus_position, live_bus_nearstop,
-- live_bus_fast. This is the volume that decides the whole design -- roughly
-- 10 GB a day across the two bus sources, so ~900 GB at steady state.
--
-- Pruned by DROP PARTITION rather than DELETE: a nightly DELETE of a day's rows
-- writes an equal volume of undo log, fragments the table, and returns no space
-- to the OS. Granularity is therefore a month, so 90 days means 90-120 days in
-- practice.
CREATE TABLE IF NOT EXISTS live_archive_bus (
  id            BIGINT      NOT NULL AUTO_INCREMENT,
  dataset       VARCHAR(64) NOT NULL,             -- 'live_bus_eta', 'live_bus_fast', ...
  partition_val VARCHAR(64) NOT NULL DEFAULT '',  -- city, or city/blob for Data.taipei
  recorded_at   DATETIME    NOT NULL,
  payload       LONGBLOB    NOT NULL,
  PRIMARY KEY (id, recorded_at),
  KEY idx_stream (dataset, partition_val, recorded_at)
) ENGINE=InnoDB
PARTITION BY RANGE (TO_DAYS(recorded_at)) (
  PARTITION p2026_08 VALUES LESS THAN (TO_DAYS('2026-09-01')),
  PARTITION p_max    VALUES LESS THAN MAXVALUE
);

-- p_max exists so a write never fails while the partition job is behind, not as
-- a place for rows to live. maintainArchivePartitions reorganizes it into the
-- coming months on every run and drops the expired ones. It covers
-- bus_eta_history and bike_availability_history too, which is what keeps the
-- former's hand-written list from running out on 2027-08-01 the way
-- 2026-08-02-history-partitions.sql warned it would.
--
-- Verify after applying:
--
--   SELECT table_name, partition_name, table_rows
--     FROM information_schema.partitions
--    WHERE table_name IN ('live_archive','live_archive_bus')
--    ORDER BY table_name, partition_ordinal_position;
