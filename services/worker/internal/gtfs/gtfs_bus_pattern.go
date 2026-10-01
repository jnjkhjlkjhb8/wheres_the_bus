package gtfs

import "github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"

const _busStopBoardingSQL = `
  SELECT
    r.subrouteuid AS sub_route_uid,
    COALESCE(r.direction, 0) AS direction,
    c->>'StopUID' AS stop_uid,
    max(CASE WHEN (c->>'StopBoarding')::int = 2 THEN 1 ELSE 0 END) AS pickup,
    max(CASE WHEN (c->>'StopBoarding')::int = 1 THEN 1 ELSE 0 END) AS drop_off
  FROM raw_tdx.bus_stopofroute r
  CROSS JOIN LATERAL jsonb_array_elements(r.stops) c
  WHERE jsonb_typeof(r.stops) = 'array'
    AND COALESCE(r.subrouteuid, '') <> ''
    AND COALESCE(c->>'StopUID', '') <> ''
    AND (c->>'StopBoarding') ~ '^[12]$'
  GROUP BY 1, 2, 3`

var _busOriginTripSource = `
  SELECT
    s.routeuid,
    s.subrouteuid,
    COALESCE(s.direction, 0) AS direction_id,
    s.subrouteuid || ':' || COALESCE(s.direction, 0)::text || ':'
      || replace(t.value->'StopTimes'->0->>'DepartureTime', ':', '') || ':'
      || ` + gtfsWeekMaskSQL("t.value->'ServiceDay'") + ` AS trip_id,
    ` + gtfsWeekMaskSQL("t.value->'ServiceDay'") + ` AS service_id,
    s.subroutename->>'Zh_tw' AS headsign,
    CASE WHEN (t.value->>'IsLowFloor')::boolean THEN 1 ELSE 0 END AS wheelchair,
    split_part(t.value->'StopTimes'->0->>'DepartureTime', ':', 1)::int * 3600
      + split_part(t.value->'StopTimes'->0->>'DepartureTime', ':', 2)::int * 60 AS origin_secs
  FROM raw_tdx.bus_schedule s
  CROSS JOIN LATERAL jsonb_array_elements(s.timetables) t
  WHERE jsonb_typeof(s.timetables) = 'array'
    AND jsonb_typeof(t.value->'StopTimes') = 'array'
    AND jsonb_typeof(t.value->'ServiceDay') = 'object'
    AND COALESCE(s.subrouteuid, '') <> ''
    AND COALESCE(s.routeuid, '') <> ''
    AND (t.value->'StopTimes'->0->>'DepartureTime') ~ '^[0-9]{1,2}:[0-9]{2}$'
    -- Exactly one call: the origin. Anything richer is busScheduleSource's.
    AND (
      SELECT count(DISTINCT c->>'StopUID') FROM jsonb_array_elements(t.value->'StopTimes') c
      WHERE COALESCE(c->>'StopUID', '') <> ''
    ) = 1
    -- The same departure and mask published again with a real call list belongs
    -- to busScheduleSource. Only this row's own timetables are searched: a
    -- trip_id names one subroute and direction, so that is the whole collision
    -- domain. The departure is compared as raw text because trip_id is built
    -- from raw text — '6:10' and '06:10' are different trips downstream, so they
    -- are different trips here.
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(s.timetables) o
      WHERE jsonb_typeof(o.value->'StopTimes') = 'array'
        AND jsonb_typeof(o.value->'ServiceDay') = 'object'
        AND (o.value->'StopTimes'->0->>'DepartureTime')
              = (t.value->'StopTimes'->0->>'DepartureTime')
        AND ` + gtfsWeekMaskSQL("o.value->'ServiceDay'") + `
              = ` + gtfsWeekMaskSQL("t.value->'ServiceDay'") + `
        AND (
          SELECT count(DISTINCT c->>'StopUID')
          FROM jsonb_array_elements(o.value->'StopTimes') c
          WHERE COALESCE(c->>'StopUID', '') <> ''
        ) > 1
    )`

// _busPatternTripsSQL is the trips.txt branch: an origin departure only becomes a
// trip when its route direction has a complete pattern to hang on.
var _busPatternTripsSQL = `
  SELECT
    b.routeuid AS route_id,
    b.service_id,
    b.trip_id,
    COALESCE(b.headsign, '') AS trip_headsign,
    '' AS trip_short_name,
    b.direction_id,
    b.wheelchair AS wheelchair_accessible,
    CASE WHEN EXISTS (
      SELECT 1 FROM raw_tdx.bus_shape sh
      WHERE sh.subrouteuid = b.subrouteuid
        AND COALESCE(sh.direction, 0) = b.direction_id
        AND sh.geometry LIKE 'LINESTRING%'
    ) THEN 'B:' || b.subrouteuid || ':' || b.direction_id::text
    ELSE '' END AS shape_id
  FROM (` + _busOriginTripSource + `) b
  WHERE EXISTS (
    SELECT 1 FROM (` + busmodel.PatternSQL + `) p
    WHERE p.sub_route_uid = b.subrouteuid AND p.direction = b.direction_id AND p.complete
  )`

// busPatternStopTimesSQL is the stop_times.txt branch: the origin departure plus
// each stop's cumulative offset. Arrival and departure are the same instant —
// the running times carry no dwell, so claiming one would be inventing it.
var _busPatternStopTimesSQL = `
  SELECT
    b.trip_id,
    p.stop_sequence,
    p.stop_uid AS stop_id,
    b.origin_secs + p.offset_secs AS arr,
    b.origin_secs + p.offset_secs AS dep,
    COALESCE(sb.pickup, 0) AS pickup,
    COALESCE(sb.drop_off, 0) AS drop_off
  FROM (` + _busOriginTripSource + `) b
  JOIN (` + busmodel.PatternSQL + `) p
    ON p.sub_route_uid = b.subrouteuid AND p.direction = b.direction_id
  LEFT JOIN (` + _busStopBoardingSQL + `) sb
    ON sb.sub_route_uid = p.sub_route_uid
   AND sb.direction     = p.direction
   AND sb.stop_uid      = p.stop_uid
  WHERE p.complete`
