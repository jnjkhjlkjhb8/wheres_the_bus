-- saveStationGroups' InterCity member insert probes bus_station_groups by
-- group_name equality (same-name cross-city grouping, bus_static.go c3). With
-- no name index each of ~15k InterCity stations seq-scans ~35k groups with a
-- geography ST_DWithin filter (~260k cost per probe), pinning the B1ms CPU for
-- 10+ minutes until the server falls over. Name equality is the selective
-- predicate; this index turns each probe into a few-row lookup.
CREATE INDEX IF NOT EXISTS bus_station_groups_group_name
    ON bus_station_groups (group_name);
