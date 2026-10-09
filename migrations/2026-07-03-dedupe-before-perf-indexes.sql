DELETE FROM bus_schedule b
USING (
    SELECT ctid
    FROM (
        SELECT
            ctid,
            row_number() OVER (
                PARTITION BY sub_route_uid, direction, type, service_day, tripid, "stop_uid/MinHeadwayMins"
                ORDER BY ctid
            ) AS rn
        FROM bus_schedule
    ) ranked
    WHERE rn > 1
) d
WHERE b.ctid = d.ctid;

DELETE FROM mrt_schedule m
USING (
    SELECT ctid
    FROM (
        SELECT
            ctid,
            row_number() OVER (
                PARTITION BY station_id, lineid, destinationstaionid, serviceday, system
                ORDER BY ctid
            ) AS rn
        FROM mrt_schedule
    ) ranked
    WHERE rn > 1
) d
WHERE m.ctid = d.ctid;
