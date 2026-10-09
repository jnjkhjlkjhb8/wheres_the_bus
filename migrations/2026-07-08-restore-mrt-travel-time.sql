-- Restore mrt_journey_matrix.travel_time_min. The 2026-07-06 drop was reverted:
-- the Metro ODFare feed does carry per-OD TravelTime (whole minutes), which the
-- functions loader (services/functions/mrt.go) parses and upserts. Idempotent,
-- so it is safe whether or not the drop was ever applied. DEFAULT 0 marks an
-- unknown/unsourced time (the client renders it as "—").
ALTER TABLE mrt_journey_matrix
    ADD COLUMN IF NOT EXISTS travel_time_min INTEGER NOT NULL DEFAULT 0;
