CREATE TABLE IF NOT EXISTS firebase_device (
    install_id           TEXT        PRIMARY KEY,
    install_secret_hash  BYTEA       NOT NULL CHECK (octet_length(install_secret_hash) = 32),
    fcm_token            TEXT        NOT NULL DEFAULT '',
    platform             TEXT        NOT NULL CHECK (platform IN ('android', 'ios')),
    app_version          TEXT        NOT NULL DEFAULT '',
    push_enabled         BOOLEAN     NOT NULL DEFAULT TRUE,
    analytics_enabled    BOOLEAN     NOT NULL DEFAULT TRUE,
    crashlytics_enabled  BOOLEAN     NOT NULL DEFAULT TRUE,
    performance_enabled BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (NOT push_enabled OR fcm_token <> '')
);

CREATE INDEX IF NOT EXISTS firebase_device_token_idx
    ON firebase_device (fcm_token) WHERE fcm_token <> '';

CREATE TABLE IF NOT EXISTS firebase_route_subscription (
    install_id TEXT        NOT NULL REFERENCES firebase_device(install_id) ON DELETE CASCADE,
    route_type TEXT        NOT NULL,
    route_key  TEXT        NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (install_id, route_type, route_key),
    CHECK (route_type IN ('bus', 'mrt', 'tra', 'thsr'))
);

CREATE INDEX IF NOT EXISTS firebase_route_subscription_route_idx
    ON firebase_route_subscription (route_type, route_key);

CREATE TABLE IF NOT EXISTS firebase_arrival_reminder (
    reminder_id  TEXT        PRIMARY KEY,
    install_id   TEXT        NOT NULL REFERENCES firebase_device(install_id) ON DELETE CASCADE,
    route_type   TEXT        NOT NULL,
    route_key    TEXT        NOT NULL,
    stop_key     TEXT        NOT NULL,
    direction    TEXT        NOT NULL,
    lead_minutes SMALLINT    NOT NULL CHECK (lead_minutes BETWEEN 1 AND 120),
    fire_at      TIMESTAMPTZ,
    expires_at   TIMESTAMPTZ NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sending', 'cancelled', 'fired', 'expired')),
    fired_at     TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (route_type IN ('bus', 'mrt', 'tra', 'thsr')),
    CHECK (fired_at IS NULL OR status = 'fired')
);

CREATE INDEX IF NOT EXISTS firebase_arrival_reminder_fire_idx
    ON firebase_arrival_reminder (fire_at) WHERE status = 'pending' AND fire_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS firebase_arrival_reminder_owner_idx
    ON firebase_arrival_reminder (install_id, status);
