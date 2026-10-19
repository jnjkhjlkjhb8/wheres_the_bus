-- 2026-08-02-history-partitions.sql — MySQL, NOT PostgreSQL.
--
-- Apply by hand on the history host, like every file in this subdirectory:
--
--   mysql bus < migrations/mysql/2026-08-02-history-partitions.sql
--
-- Why now: the segment rebuild moved off PostgreSQL and onto this host
-- (computeSegmentTimesFromEstimates; a second plate-pairing pass was removed
-- 2026-08-02, see services/functions/segment_time.go). It scans
-- bus_eta_history by recorded_at alone — 14 days — and nothing on the table
-- serves that filter:
--
--   * The declared partitioning is inert. p_init covers everything before
--     2026-09-01 and p_max is MAXVALUE, so today every row is in one partition
--     and RANGE pruning removes nothing. It was written to be split later and
--     the splitting never happened.
--   * The only key is idx_lookup (sub_route_uid, stop_uid, direction,
--     recorded_at). recorded_at is the fourth column, so a query with no
--     equality on the first three cannot use it.
--
-- That is a full table scan every night, on a table that nothing prunes — the retention job that used to bound it was for the
-- PostgreSQL copy and did not follow the data here. It is survivable at a few
-- million rows and is not at 70 million.
--
-- Pruning is the fix that scales; the index only narrows the scan inside a
-- partition it cannot skip. Both are here because the daily readers want the
-- first and measurePredictionError's arrivals lookup wants the second.

-- Monthly partitions from 2026-09 forward, so a 14-day window touches at most
-- two of them.
--
-- REORGANIZE rewrites only the partitions it names. p_max is empty today
-- (nothing has a recorded_at past 2026-09-01 yet), so this is a catalog change
-- that returns immediately. Run it before September and it stays that way;
-- run it after and it rewrites however much has landed in p_max by then.
--
-- p_init is deliberately left whole. It holds everything written since the
-- table was created on 2026-07-30 — about one month — which is within the
-- window the readers ask for anyway, so splitting it would rewrite the entire
-- table to buy nothing.
ALTER TABLE bus_eta_history
  REORGANIZE PARTITION p_max INTO (
    PARTITION p2026_09 VALUES LESS THAN (TO_DAYS('2026-10-01')),
    PARTITION p2026_10 VALUES LESS THAN (TO_DAYS('2026-11-01')),
    PARTITION p2026_11 VALUES LESS THAN (TO_DAYS('2026-12-01')),
    PARTITION p2026_12 VALUES LESS THAN (TO_DAYS('2027-01-01')),
    PARTITION p2027_01 VALUES LESS THAN (TO_DAYS('2027-02-01')),
    PARTITION p2027_02 VALUES LESS THAN (TO_DAYS('2027-03-01')),
    PARTITION p2027_03 VALUES LESS THAN (TO_DAYS('2027-04-01')),
    PARTITION p2027_04 VALUES LESS THAN (TO_DAYS('2027-05-01')),
    PARTITION p2027_05 VALUES LESS THAN (TO_DAYS('2027-06-01')),
    PARTITION p2027_06 VALUES LESS THAN (TO_DAYS('2027-07-01')),
    PARTITION p2027_07 VALUES LESS THAN (TO_DAYS('2027-08-01')),
    PARTITION p_max    VALUES LESS THAN MAXVALUE
  );

-- The list runs out on 2027-08-01. After that every row lands in p_max again
-- and pruning stops helping — silently, since nothing fails. Extending it is
-- another dated migration like this one; nothing automates that today.

-- recorded_at as a leading column, for the readers that filter on it without
-- naming a subroute. It costs one more index to maintain on a table written
-- every 30 seconds; the writes are batched 1000 rows to a statement
-- (archiveRowsPerInsert), so the amortised cost is small against two nightly
-- scans it keeps off the disk.
--
-- MySQL has no CREATE INDEX IF NOT EXISTS. Re-running this file therefore
-- fails here with ER_DUP_KEYNAME (1061) rather than being a no-op — that is
-- the expected outcome on an already-applied host, not a problem to fix.
ALTER TABLE bus_eta_history
  ADD KEY idx_recorded (recorded_at);

-- Verify after applying:
--
--   SELECT partition_name, table_rows FROM information_schema.partitions
--    WHERE table_name = 'bus_eta_history' ORDER BY partition_ordinal_position;
--
--   EXPLAIN SELECT COUNT(*) FROM bus_eta_history
--    WHERE recorded_at >= UTC_TIMESTAMP() - INTERVAL 7 DAY;
--   -- expect `partitions` to name a subset, not every partition.
--
-- Not addressed here: bike_availability_history carries the identical inert
-- p_init/p_max declaration. It has no online reader, so nothing scans it today
-- and the same REORGANIZE can wait until something does.
