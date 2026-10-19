-- bus_travel_avg_stop was replaced by bus_segment_time and dropped by
-- 2026-07-31-bus-segment-time.sql, but that drop never reached Azure, so the
-- restored cluster still carries the empty table. No code reads or writes it
-- (FDPL-120). A no-op on a replayed database.

DROP TABLE IF EXISTS bus_travel_avg_stop;
