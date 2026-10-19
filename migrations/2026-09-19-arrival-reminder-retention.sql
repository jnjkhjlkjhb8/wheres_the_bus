-- Bound reminder growth while preserving recent terminal rows for support.
CREATE INDEX IF NOT EXISTS firebase_arrival_reminder_retention_idx
    ON firebase_arrival_reminder (updated_at)
    WHERE status IN ('cancelled', 'fired', 'expired');

CREATE UNIQUE INDEX IF NOT EXISTS firebase_arrival_reminder_active_identity_idx
    ON firebase_arrival_reminder (install_id, route_type, route_key, stop_key, direction, plate, alight_event)
    WHERE status IN ('pending', 'sending');
