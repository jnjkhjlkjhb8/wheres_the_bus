-- Which 下車提醒 buzz a reminder row fires: 'lead' (提前提醒站, short) or
-- 'alight' (下車站, long). Empty string = a legacy arrival reminder, which
-- still sends a banner notification. See ADR-0020.
ALTER TABLE firebase_arrival_reminder
    ADD COLUMN IF NOT EXISTS alight_event TEXT NOT NULL DEFAULT '';
