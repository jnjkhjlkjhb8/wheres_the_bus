CREATE TABLE IF NOT EXISTS bus_station_groups (
    group_uid  TEXT PRIMARY KEY,
    group_id   TEXT NOT NULL,
    group_name TEXT NOT NULL,
    city       TEXT NOT NULL,
    position   GEOMETRY(Point, 4326) NOT NULL,
    source     TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS bus_station_groups_city_group_id
    ON bus_station_groups (city, group_id);

CREATE INDEX IF NOT EXISTS bus_station_groups_position
    ON bus_station_groups USING gist (position);

CREATE TABLE IF NOT EXISTS bus_station_group_members (
    station_uid  TEXT PRIMARY KEY,
    group_uid    TEXT NOT NULL REFERENCES bus_station_groups(group_uid) ON DELETE CASCADE,
    station_id   TEXT NOT NULL,
    station_name TEXT NOT NULL,
    city         TEXT NOT NULL,
    position     GEOMETRY(Point, 4326) NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS bus_station_group_members_group_uid
    ON bus_station_group_members (group_uid);
