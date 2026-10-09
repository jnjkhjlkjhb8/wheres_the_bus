-- 2026-07-31-bus-segment-time.sql
-- Hand-applied to Azure: psql "$DATABASE_URL" -f migrations/2026-07-31-bus-segment-time.sql
--
-- Replaces bus_travel_avg_stop, added hours earlier the same day and never
-- populated, with the shape the observations actually support: the running time
-- between two consecutive stops, rather than the cumulative time from the
-- subroute's departure.
--
-- Why the change. A cumulative figure needs a departure time to measure from, so
-- every observation has to be matched against bus_schedule and discarded when no
-- departure lines up. A segment needs nothing but two arrivals by the same
-- vehicle, which removes that dependency entirely. Measured over the same seven
-- days of history:
--
--   cumulative from departure       34 subroutes
--   segment between stops        2,395 subroutes
--
-- Segments also compose. Laying out a trip means accumulating them along the
-- stop sequence, and a segment nobody observed leaves a gap at one hop instead
-- of invalidating everything downstream of it, which is what a missing
-- cumulative value does.
--
-- This is the same shape TDX publishes for metro (Rail/Metro/S2STravelTime) and
-- for the bus cities it covers, so a consumer can fall back between sources
-- without reshaping anything.
--
-- Dropping rather than altering: the table is empty, was created today, and
-- nothing reads it yet.

DROP TABLE IF EXISTS bus_travel_avg_stop;

CREATE TABLE IF NOT EXISTS bus_segment_time (
    sub_route_uid  text        NOT NULL,
    direction      smallint    NOT NULL,
    from_stop_uid  text        NOT NULL,
    to_stop_uid    text        NOT NULL,
    -- Median seconds between arriving at from_stop and arriving at to_stop, not
    -- a mean: one bus held at a light skews an average and leaves a median alone.
    secs           integer     NOT NULL,
    -- How many observations the median came from. Stored so a reader sets its
    -- own confidence bar instead of inheriting the writer's: the GTFS export can
    -- insist on several, a diagnostic can take one.
    sample_count   integer     NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (sub_route_uid, direction, from_stop_uid, to_stop_uid)
);

-- Laying out one trip reads a whole subroute direction's segments at once.
CREATE INDEX IF NOT EXISTS bus_segment_time_subroute_idx
    ON bus_segment_time (sub_route_uid, direction);
