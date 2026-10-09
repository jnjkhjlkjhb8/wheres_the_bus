-- Prediction error measurement for bus ETA. One row per prediction made for a
-- stop TDX left blank (or a TDX ETA sampled for comparison); a later cron fills
-- actual_seconds by matching the prediction to the observed arrival in
-- bus_eta_history. Aggregated as MAE per route per source; no dashboard.
-- 30-day retention piggybacks on the daily cleanupBusHistory job.

CREATE TABLE IF NOT EXISTS bus_eta_prediction_error (
    id                BIGSERIAL   PRIMARY KEY,
    sub_route_uid     TEXT        NOT NULL,
    direction         SMALLINT    NOT NULL,
    stop_uid          TEXT        NOT NULL,
    -- one of: tdx, propagation, model, travel_avg, schedule
    source            TEXT        NOT NULL,
    predicted_at      TIMESTAMPTZ NOT NULL,
    predicted_seconds INT         NOT NULL,
    -- NULL until the matching cron observes the actual arrival
    actual_seconds    INT
);

-- Fill-actuals and MAE aggregation both scan by (stop, time); this covers the
-- correlated arrival match and the daily group-by.
CREATE INDEX IF NOT EXISTS bus_eta_prediction_error_lookup
    ON bus_eta_prediction_error (sub_route_uid, direction, stop_uid, predicted_at);

-- Retention cleanup filters on predicted_at (piggybacks cleanupBusHistory).
CREATE INDEX IF NOT EXISTS bus_eta_prediction_error_predicted_at
    ON bus_eta_prediction_error (predicted_at);
