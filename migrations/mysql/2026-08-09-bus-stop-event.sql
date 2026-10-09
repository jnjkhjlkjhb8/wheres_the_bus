-- 2026-08-09-bus-stop-event.sql — MySQL, NOT PostgreSQL.
--
-- Applied by hand on the archive host, like every file in this directory:
--
--   mysql bus < migrations/mysql/2026-08-09-bus-stop-event.sql
--
-- Observed stop arrivals and departures, from TDX's A2 feed
-- (Bus/RealTimeNearStop, fetched for 公路總局 and the counties it manages —
-- services/functions/bus_nearstop.go). Every other travel-time figure this
-- system holds is derived from N1 countdowns, which are the source's own
-- estimate; these rows are the times a vehicle actually reached a stop.
--
-- Conventions follow 2026-07-30-history-archive.sql: UTC DATETIMEs normalized by
-- the writer (archiveUTC), and rows appended by the same background flusher.
--
-- Two departures from that file:
--   * There is a natural key. TDX keeps each vehicle's last A2 record for two
--     hours and the ETA tick re-reads it every 30 seconds, so the same event
--     arrives again and again; the primary key makes the writer's INSERT IGNORE
--     drop the repeat at the database instead of tracking seen events in the
--     process. There is therefore no AUTO_INCREMENT id.
--   * event_time is the vehicle's own GPSTime — when the event happened, not
--     when this system heard about it. recorded_at keeps the latter.
--
-- Not partitioned: partitioning demands the partition column in every unique
-- key, which would put recorded_at in the primary key and defeat the
-- deduplication that is the point of it. Size this from measured volume before
-- deciding it needs one.
--
-- event_type is stored as TDX sends its A2EventType: 1 arrival, 0 departure.
-- Established by sampling the feed twice a minute apart (2026-08-09) — vehicles
-- whose record moved while staying at one stop always went 1 -> 0, never the
-- reverse — since the field's codes are not documented.
CREATE TABLE IF NOT EXISTS bus_stop_event (
  plate_numb           VARCHAR(32) NOT NULL,
  city                 VARCHAR(32) NOT NULL,
  sub_route_uid        VARCHAR(64) NOT NULL,
  direction            SMALLINT    NOT NULL,
  stop_uid             VARCHAR(64) NOT NULL,
  stop_sequence        SMALLINT    NOT NULL,
  event_type           SMALLINT    NOT NULL,
  event_time           DATETIME    NOT NULL,
  trip_start_time      DATETIME        NULL,
  trip_start_time_type SMALLINT    NOT NULL,
  recorded_at          DATETIME    NOT NULL,
  PRIMARY KEY (plate_numb, stop_uid, event_type, event_time),
  KEY idx_segment (sub_route_uid, direction, stop_sequence, event_time)
) ENGINE=InnoDB;
