-- TDX's DisplayStopOfRoute: a route's stops linearised across its branches.
--
-- StopOfRoute stores how each subroute actually runs, which is the right shape
-- for an estimate and the wrong one for a page: a route that forks and rejoins
-- (307 經西藏路 / 307 經莒光路) becomes several lists a rider has to reconcile.
-- TDX publishes this second, route-level list so one page can show the whole
-- route with every branch's arrivals laid over it. It exists for the five cities
-- that define one — Taipei, NewTaipei, Taoyuan, Taichung, Tainan — and every
-- other city answers HTTP 400 naming exactly those five, with InterCity 404 on
-- both v2 and v3 (verified 2026-08-09). The landing set is those five.
--
-- Landed and stored only; no reader yet (FDPL-84 covers the route screen).

CREATE TABLE IF NOT EXISTS raw_tdx.bus_displaystopofroute (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    direction smallint,
    stops jsonb,
    updatetime timestamptz,
    versionid integer,
    fetched_at timestamptz NOT NULL DEFAULT now(),
    landing_cycle text
);

DROP TRIGGER IF EXISTS trg_set_fetched_at ON raw_tdx.bus_displaystopofroute;
CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_displaystopofroute
    FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();

-- The loaded form, mirroring bus_station_stop_map's shape one level up: keyed by
-- route rather than subroute, because that is the whole point of the list.
CREATE TABLE IF NOT EXISTS bus_display_stop_map (
	route_uid     text        NOT NULL,
	direction     smallint    NOT NULL,
	stop_uid      text        NOT NULL,
	stop_sequence smallint    NOT NULL,
	station_id    text        NOT NULL,
	stop_name     text        NOT NULL,
	updated_at    timestamptz NOT NULL DEFAULT NOW(),
	PRIMARY KEY (route_uid, direction, stop_uid)
);

-- One route's list is read in stop order, the only access this table has.
CREATE INDEX IF NOT EXISTS bus_display_stop_map_route_idx
	ON bus_display_stop_map (route_uid, direction, stop_sequence);
