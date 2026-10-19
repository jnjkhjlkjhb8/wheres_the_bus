-- Split the metro OD fare into full (全票) and half (半票). fare_nt was always
-- meant to hold the adult full fare (services/router/maas.go sectionFare, which
-- reads fare_class = 1 for THSR/TRA), but the loader filtered the ODFare Fares[]
-- array on TicketType alone and kept the last match — a discounted FareClass —
-- so every row held a half fare. services/functions/mrt.go now matches both axes
-- (TicketType 1 = 單程票, FareClass 1 = 全票 / 2 = 半票) and writes each to its own
-- column; the next 03:30 loader run overwrites the existing wrong fare_nt values.
-- DEFAULT 0 marks an unknown/unsourced fare (the upsert never overwrites a known
-- price with a 0).
ALTER TABLE mrt_journey_matrix
    ADD COLUMN IF NOT EXISTS half_fare_nt INTEGER NOT NULL DEFAULT 0;
