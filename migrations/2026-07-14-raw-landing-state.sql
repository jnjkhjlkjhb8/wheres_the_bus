BEGIN;

CREATE TABLE IF NOT EXISTS raw_tdx.landing_state (
    table_name       text        NOT NULL,
    partition_column text        NOT NULL DEFAULT '',
    partition_value  text        NOT NULL DEFAULT '',
    last_modified    text        NOT NULL,
    row_count        bigint      NOT NULL CHECK (row_count >= 0),
    fetched_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (table_name, partition_column, partition_value),
    CHECK (table_name <> ''),
    CHECK (last_modified <> ''),
    CHECK (partition_column IN ('', 'city', 'system', 'traindate')),
    CHECK (
        (partition_column = '' AND partition_value = '')
        OR (partition_column <> '' AND partition_value <> '')
    )
);

COMMENT ON TABLE raw_tdx.landing_state IS
    'Durable validation metadata for conditional TDX raw landings; deploy before ingestor/loader binaries that read it.';

COMMIT;
