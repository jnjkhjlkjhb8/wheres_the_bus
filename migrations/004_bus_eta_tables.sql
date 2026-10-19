CREATE TABLE IF NOT EXISTS bus_eta_history (
    id              BIGSERIAL    PRIMARY KEY,
    sub_route_uid   TEXT         NOT NULL,
    stop_uid        TEXT         NOT NULL,
    direction       SMALLINT     NOT NULL,
    stop_sequence   SMALLINT     NOT NULL,
    total_stops     SMALLINT     NOT NULL,
    estimate        INT          NOT NULL,
    next_bus_time   TEXT,
    src_update_time TIMESTAMPTZ,
    recorded_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    city            TEXT         NOT NULL,
    hour            SMALLINT     NOT NULL,
    day_of_week     SMALLINT     NOT NULL,
    is_holiday      BOOLEAN      NOT NULL,
    temperature     REAL,
    precipitation   REAL,
    wind_speed      REAL,
    humidity        REAL,
    plate_numb      TEXT,
    bus_speed       SMALLINT,
    bus_distance_m  INT
);

CREATE INDEX IF NOT EXISTS bus_eta_history_lookup
    ON bus_eta_history (sub_route_uid, stop_uid, direction, recorded_at DESC);

CREATE TABLE IF NOT EXISTS bus_travel_avg (
    sub_route_uid TEXT        NOT NULL,
    direction     SMALLINT    NOT NULL,
    stop_uid      TEXT        NOT NULL,
    hour          SMALLINT    NOT NULL,
    day_of_week   SMALLINT    NOT NULL,
    avg_seconds   INT         NOT NULL,
    sample_count  INT         NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (sub_route_uid, direction, stop_uid, hour, day_of_week)
);
