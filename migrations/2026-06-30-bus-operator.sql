CREATE TABLE bus_operators (
    operator_id    TEXT NOT NULL,
    authority_code TEXT NOT NULL,
    operator_name  TEXT NOT NULL,
    operator_phone TEXT,
    operator_url   TEXT,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (operator_id, authority_code)
);

ALTER TABLE bus_subroutes ADD COLUMN operators JSONB;
