-- Published static data and the GTFS-RT index frozen with it (ADR-0026, FDPL-107).
--
-- A nightly pipeline run exports its GTFS feed and, from the same data, the
-- index GTFS-RT matches live vehicles against. Both are keyed by the run's
-- run_id (the Kubernetes Job UID). The run becomes the published one only when
-- `pipeline run publish` adds its static_release row, after MOTIS has loaded the
-- same feed, so realtime never pairs a new index with an old MOTIS dataset.
-- build_seq orders runs; run_id only identifies them.

BEGIN;

CREATE SEQUENCE IF NOT EXISTS static_build_seq;

CREATE TABLE IF NOT EXISTS static_release (
    run_id       text PRIMARY KEY,
    build_seq    bigint NOT NULL UNIQUE,
    gtfs_sha256  text NOT NULL,
    published_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS gtfs_rt_bus_trip (
    run_id       text NOT NULL,
    trip_id      text NOT NULL,
    direction_id integer NOT NULL,
    service_id   text NOT NULL
);
CREATE INDEX IF NOT EXISTS gtfs_rt_bus_trip_run_idx ON gtfs_rt_bus_trip (run_id);

CREATE TABLE IF NOT EXISTS gtfs_rt_rail_trip (
    run_id       text NOT NULL,
    service_date date NOT NULL,
    train_no     text NOT NULL,
    trip_id      text NOT NULL,
    stations     text[] NOT NULL
);
CREATE INDEX IF NOT EXISTS gtfs_rt_rail_trip_run_date_idx ON gtfs_rt_rail_trip (run_id, service_date);

CREATE TABLE IF NOT EXISTS gtfs_rt_bus_offset (
    run_id        text NOT NULL,
    sub_route_uid text NOT NULL,
    direction     integer NOT NULL,
    stop_uid      text NOT NULL,
    offset_secs   bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS gtfs_rt_bus_offset_run_idx ON gtfs_rt_bus_offset (run_id);

-- pipeline_svc writes; every other service reads (catalog rule, 2026-10-07).
GRANT SELECT, INSERT, UPDATE, DELETE ON static_release, gtfs_rt_bus_trip, gtfs_rt_rail_trip, gtfs_rt_bus_offset TO pipeline_svc;
GRANT SELECT ON static_release, gtfs_rt_bus_trip, gtfs_rt_rail_trip, gtfs_rt_bus_offset TO api_svc, realtime_svc, rider_svc;
GRANT USAGE, SELECT ON SEQUENCE static_build_seq TO pipeline_svc;

COMMIT;
