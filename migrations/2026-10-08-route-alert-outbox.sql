-- Route alerts from realtime's MQTT subscriber to rider's push dispatch
-- (ADR-0026, FDPL-108).
--
-- realtime inserts one row per (route_type, route_key, alert id); the unique
-- dedupe_key makes a re-delivered MQTT message a no-op. rider-worker claims
-- rows with FOR UPDATE SKIP LOCKED, sends, and stamps processed_at. A crash
-- between the push and the stamp leaves the claim to expire and the row is
-- sent again, so delivery is at-least-once. Rows past their retry budget or
-- older than a day are never sent.

BEGIN;

CREATE TABLE IF NOT EXISTS route_alert_outbox (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dedupe_key    text NOT NULL UNIQUE,
    route_type    text NOT NULL,
    route_key     text NOT NULL,
    body          text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    attempts      integer NOT NULL DEFAULT 0,
    claimed_until timestamptz,
    processed_at  timestamptz
);
CREATE INDEX IF NOT EXISTS route_alert_outbox_pending_idx
    ON route_alert_outbox (id) WHERE processed_at IS NULL;

GRANT SELECT, INSERT ON route_alert_outbox TO realtime_svc;
GRANT USAGE, SELECT ON SEQUENCE route_alert_outbox_id_seq TO realtime_svc;
GRANT SELECT, UPDATE, DELETE ON route_alert_outbox TO rider_svc;
GRANT SELECT ON route_alert_outbox TO api_svc, pipeline_svc;

COMMIT;
