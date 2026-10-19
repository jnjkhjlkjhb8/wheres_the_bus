-- 2026-07-31-bus-travel-avg-stop.sql
-- Hand-applied to Azure: psql "$DATABASE_URL" -f migrations/2026-07-31-bus-travel-avg-stop.sql
--
-- A second, coarser view of the same observations that feed bus_travel_avg:
-- one average per (subroute, direction, stop), with no hour or weekday.
--
-- Why a second table rather than a query over the first. bus_travel_avg is keyed
-- by hour and day of week — 168 buckets per stop — and a bucket is only written
-- once three arrivals land in it. At the observation rate this project sees,
-- 58,282 arrivals over seven days, that leaves 239 rows covering 34 subroutes.
-- Aggregating those survivors would inherit the thinness: the arrivals have
-- already been discarded by then. Bucketing the same arrivals by stop alone,
-- before the threshold applies, is what recovers the coverage.
--
-- Who reads which. ETA prediction (predict.go) wants the time-of-day profile and
-- reads bus_travel_avg. The GTFS export wants one representative time per stop
-- to turn a departure schedule into stop times, and reads this. Neither is a
-- substitute for the other, so both are written by the same job from one pass
-- over the arrivals.
--
-- sample_count is carried so a reader can set its own confidence bar rather than
-- inheriting the writer's.

CREATE TABLE IF NOT EXISTS bus_travel_avg_stop (
    sub_route_uid text        NOT NULL,
    direction     smallint    NOT NULL,
    stop_uid      text        NOT NULL,
    -- Median seconds from the subroute's departure to this stop, not a mean:
    -- a bus held at one light skews an average and leaves a median alone.
    avg_seconds   integer     NOT NULL,
    sample_count  integer     NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (sub_route_uid, direction, stop_uid)
);

-- The GTFS export reads a whole subroute's stops at once to lay out one trip.
CREATE INDEX IF NOT EXISTS bus_travel_avg_stop_subroute_idx
    ON bus_travel_avg_stop (sub_route_uid, direction);
