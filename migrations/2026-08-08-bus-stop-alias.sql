-- Co-operated bus routes publish one StopOfRoute list per operator, and the same
-- physical stop carries a different StopID in each. TDX's N1 estimates are keyed
-- on the operator's own StopID, so an estimate arriving under the list the loader
-- did not keep matched nothing and the stop rendered as having no reading at all.
--
-- The loader keeps one list for ordering (bus_station_stop_map) and records every
-- other operator's UID for the same stop here, so the ETA join can resolve it.
CREATE TABLE IF NOT EXISTS bus_stop_alias (
	sub_route_uid  text        NOT NULL,
	direction      smallint    NOT NULL,
	alias_stop_uid text        NOT NULL,
	stop_uid       text        NOT NULL,
	updated_at     timestamptz NOT NULL DEFAULT NOW(),
	PRIMARY KEY (sub_route_uid, direction, alias_stop_uid)
);

-- The ETA path reads every alias of one city in one shot, the same shape as
-- bus_station_stop_map's own prefix scan.
CREATE INDEX IF NOT EXISTS bus_stop_alias_sub_route_uid_idx
	ON bus_stop_alias (sub_route_uid);
