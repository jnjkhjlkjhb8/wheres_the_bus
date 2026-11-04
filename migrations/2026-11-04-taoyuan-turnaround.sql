-- Taoyuan out-and-back routes publish one TDX direction; the city's own
-- TaoyuanRoute feed names the turnaround stop the loader splits them at
-- (FDPL-138). Both changes are additive: the running release neither reads the
-- new table nor writes the new column.

DO $$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'current_schema() is NULL; set search_path before applying';
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS raw_tdx.bus_taoyuanroute (
    city text,
    subrouteuid text,
    iscircular boolean,
    backstopuid text,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE OR REPLACE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_taoyuanroute
    FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();

GRANT SELECT, INSERT, DELETE, TRUNCATE, UPDATE ON TABLE raw_tdx.bus_taoyuanroute TO pipeline_svc;

-- StopSequence the served payload is split at; NULL serves TDX's directions.
ALTER TABLE bus_static ADD COLUMN IF NOT EXISTS turnaround_stop_sequence smallint;
