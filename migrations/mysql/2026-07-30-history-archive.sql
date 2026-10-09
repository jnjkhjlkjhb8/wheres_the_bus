-- 2026-07-30-history-archive.sql — MySQL, NOT PostgreSQL.
--
-- The long-term history archive. Everything in migrations/ except this
-- subdirectory targets the Azure PostgreSQL server; these tables live on the
-- separate MySQL host and are applied by hand there:
--
--   mysql bus < migrations/mysql/2026-07-30-history-archive.sql
--
-- Why MySQL holds these and Postgres does not:
--   * bus_eta_history — this is its only home. saveBusEtaHistory writes here
--     every 30s and both readers (computeTravelAvg's crossing scan,
--     measurePredictionError's arrival lookup) read here; the Postgres table
--     was dropped. ~200k rows/day off a 2 GB server, kept indefinitely as
--     ETA-model training data — nothing prunes it.
--   * bike_availability_history — has no online reader at all, so after the
--     bike cutover it is written straight here and the Postgres table is dropped.
--   * raw_tdx_archive — one row per distinct upstream version of a raw_tdx
--     dataset. raw_tdx is DELETEd/TRUNCATEd on every landing, and TDX only ever
--     serves "now", so an overwritten payload is unrecoverable. This is the only
--     copy of what the upstream actually said on a given day.
--
-- Conventions:
--   * All timestamps are UTC. MySQL DATETIME carries no zone; the writer calls
--     .UTC() before binding (archiveUTC) rather than trusting the DSN's `loc`.
--   * id is AUTO_INCREMENT and never supplied by the writer. These tables are
--     append-only observation logs with no natural key, so the INSERT IGNORE
--     the writer uses never actually fires on them.
--   * The two high-volume tables are partitioned by month. MySQL requires every
--     unique key to contain the partition column, hence PRIMARY KEY
--     (id, recorded_at). Retrofitting partitions later means rebuilding the
--     whole table, so they are declared up front.
--   * CORRECTION 2026-08-02: the ~197k/day below is wrong. It was measured off
--     the old inline writer, which ran on the live tick's context and died
--     mid-batch most ticks -- so it counted what landed, not what was produced.
--     Once the background flusher exposed the real rate it was ~217M rows/day.
--     The writer now records one snapshot per historySnapshotInterval (plus
--     every arrival), which is what the figures here should be re-measured
--     against before anyone sizes storage from them.
--   * Measured 2026-07-30: bus_eta_history ~197k rows/day (~33 GB/yr),
--     bike_availability_history ~11.5 MB/day (~4 GB/yr).

CREATE TABLE IF NOT EXISTS bus_eta_history (
  id              BIGINT      NOT NULL AUTO_INCREMENT,
  sub_route_uid   VARCHAR(64) NOT NULL,
  stop_uid        VARCHAR(64) NOT NULL,
  direction       SMALLINT    NOT NULL,
  stop_sequence   SMALLINT    NOT NULL,
  total_stops     SMALLINT    NOT NULL,
  estimate        INT         NOT NULL,
  next_bus_time   VARCHAR(32)     NULL,
  src_update_time DATETIME        NULL,
  recorded_at     DATETIME    NOT NULL,
  city            VARCHAR(32) NOT NULL,
  hour            TINYINT     NOT NULL,
  day_of_week     TINYINT     NOT NULL,
  is_holiday      TINYINT(1)  NOT NULL,
  temperature     FLOAT           NULL,
  precipitation   FLOAT           NULL,
  wind_speed      FLOAT           NULL,
  humidity        FLOAT           NULL,
  plate_numb      VARCHAR(32)     NULL,
  bus_speed       SMALLINT        NULL,
  bus_distance_m  INT             NULL,
  PRIMARY KEY (id, recorded_at),
  KEY idx_lookup (sub_route_uid, stop_uid, direction, recorded_at)
) ENGINE=InnoDB
PARTITION BY RANGE (TO_DAYS(recorded_at)) (
  PARTITION p_init VALUES LESS THAN (TO_DAYS('2026-09-01')),
  PARTITION p_max  VALUES LESS THAN MAXVALUE
);

CREATE TABLE IF NOT EXISTS bike_availability_history (
  id               BIGINT      NOT NULL AUTO_INCREMENT,
  station_uid      VARCHAR(64) NOT NULL,
  available_rent   SMALLINT    NOT NULL,
  available_return SMALLINT    NOT NULL,
  recorded_at      DATETIME    NOT NULL,
  PRIMARY KEY (id, recorded_at),
  KEY idx_station (station_uid, recorded_at)
) ENGINE=InnoDB
PARTITION BY RANGE (TO_DAYS(recorded_at)) (
  PARTITION p_init VALUES LESS THAN (TO_DAYS('2026-09-01')),
  PARTITION p_max  VALUES LESS THAN MAXVALUE
);

-- One table for all 20+ raw_tdx datasets rather than a mirror of each: the
-- columns of raw_tdx.* are TDX's shape, not ours, and they drift whenever TDX
-- adds a field. Storing the payload verbatim also means a replay can be fed
-- back through the same insertRawChunks path that originally landed it.
--   dataset       — the raw_tdx table name ('bus_route', 'metro_odfare', ...)
--   partition_val — city / system / date, '' for whole-table datasets
--   last_modified — the TDX If-Modified-Since marker; one row per upstream
--                   version, so a forced refetch of an unchanged payload is
--                   absorbed by uq_version instead of storing a duplicate
--   payload       — gzipped raw JSON array, exactly as TDX served it
CREATE TABLE IF NOT EXISTS raw_tdx_archive (
  id            BIGINT AUTO_INCREMENT PRIMARY KEY,
  dataset       VARCHAR(64) NOT NULL,
  partition_val VARCHAR(64) NOT NULL DEFAULT '',
  last_modified VARCHAR(64) NOT NULL,
  landing_cycle VARCHAR(64) NOT NULL,
  fetched_at    DATETIME    NOT NULL,
  payload       LONGBLOB    NOT NULL,
  UNIQUE KEY uq_version (dataset, partition_val, last_modified)
) ENGINE=InnoDB;
