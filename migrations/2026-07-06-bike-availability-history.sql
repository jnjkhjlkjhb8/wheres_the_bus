-- Realtime bike-share availability samples for future rentable/returnable
-- prediction. The bikeEta cron writes one row per station at most once every
-- 5 minutes (not every 30s round); rows older than 30 days are cleaned nightly,
-- mirroring bus_eta_history retention.
CREATE TABLE IF NOT EXISTS bike_availability_history (
    id               BIGSERIAL    PRIMARY KEY,
    station_uid      TEXT         NOT NULL,
    available_rent   SMALLINT     NOT NULL,
    available_return SMALLINT     NOT NULL,
    recorded_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS bike_availability_history_lookup
    ON bike_availability_history (station_uid, recorded_at DESC);
