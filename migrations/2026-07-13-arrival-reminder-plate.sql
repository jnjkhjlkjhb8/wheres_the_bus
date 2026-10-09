-- Pins an arrival reminder to a single vehicle. Empty string = legacy
-- next-bus reminder (unchanged firing). See ADR-0008.
ALTER TABLE firebase_arrival_reminder
    ADD COLUMN IF NOT EXISTS plate TEXT NOT NULL DEFAULT '';
