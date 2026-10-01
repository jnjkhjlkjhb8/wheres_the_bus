package gtfs

import "strconv"

const (
	railShapeSnapMeters        = 500
	railShapeSimplifyTolerance = 0.0001
)

// railShapeSnapMetersSQL and railShapeSimplifyToleranceSQL are the constants in
// the form the statements below can splice.
var (
	railShapeSnapMetersSQL        = strconv.Itoa(railShapeSnapMeters)
	railShapeSimplifyToleranceSQL = strconv.FormatFloat(railShapeSimplifyTolerance, 'f', -1, 64)
)

// The rail branch's working tables, named here in the same form as the GTFS
// table constants in gtfs_fares.go. _gtfsRailSegSQL and _gtfsRailTripShapeSQL
// are what fill them; _gtfsRailShapePointsSQL reads both back.
const (
	_gtfsRailSegTable       = "gtfs_rail_seg"
	_gtfsRailTripShapeTable = "gtfs_rail_trip_shape"
)

var _gtfsRailSegSQL = `
WITH rail_stop AS (
  SELECT s.stop_id,
         CASE WHEN s.stop_id LIKE 'TRA:%' THEN 'tra' ELSE 'thsr' END AS mode,
         ST_SetSRID(ST_MakePoint(s.stop_lon, s.stop_lat), 4326) AS pt
  FROM ` + _gtfsStopTable + ` s
  WHERE s.location_type = 0
    AND (s.stop_id LIKE 'TRA:%' OR s.stop_id LIKE 'THSR:%')
), component AS (
  -- One line may be several components: ST_LineMerge leaves a branch or a gap
  -- as its own piece, and only a single piece can be located along.
  SELECT sh.mode, sh.line_id, d.path[1] AS part, d.geom
  FROM rail_shapes sh
  CROSS JOIN LATERAL ST_Dump(ST_LineMerge(sh.geom)) d
  WHERE sh.mode IN ('tra', 'thsr')
    AND ST_GeometryType(d.geom) = 'ST_LineString'
), snapped AS (
  SELECT rs.stop_id, c.line_id, c.part, c.geom,
         ST_Distance(c.geom::geography, rs.pt::geography) AS dist,
         ST_LineLocatePoint(c.geom, rs.pt) AS frac
  FROM rail_stop rs
  JOIN component c ON c.mode = rs.mode
), near AS (
  SELECT * FROM snapped WHERE dist <= ` + railShapeSnapMetersSQL + `
), pair AS (
  SELECT DISTINCT from_stop, to_stop
  FROM (
    SELECT st.stop_id AS from_stop,
           LEAD(st.stop_id) OVER (PARTITION BY st.trip_id ORDER BY st.stop_sequence) AS to_stop
    FROM ` + _gtfsStopTimeTable + ` st
    WHERE st.trip_id LIKE 'TRA:%' OR st.trip_id LIKE 'THSR:%'
  ) s
  WHERE to_stop IS NOT NULL
), matched AS (
  SELECT DISTINCT ON (p.from_stop, p.to_stop)
    p.from_stop, p.to_stop, a.geom, a.frac AS f1, b.frac AS f2
  FROM pair p
  JOIN near a ON a.stop_id = p.from_stop
  JOIN near b ON b.stop_id = p.to_stop AND b.line_id = a.line_id AND b.part = a.part
  ORDER BY p.from_stop, p.to_stop, GREATEST(a.dist, b.dist)
)
SELECT
  from_stop,
  to_stop,
  ST_SimplifyPreserveTopology(
    CASE WHEN f1 <= f2 THEN ST_LineSubstring(geom, f1, f2)
         ELSE ST_Reverse(ST_LineSubstring(geom, f2, f1)) END,
    ` + railShapeSimplifyToleranceSQL + `) AS geom
FROM matched
-- Two stops that locate onto the same point of a line would clip to a single
-- point, which is not a segment. The stitch falls back to a straight line.
WHERE f1 <> f2`

var _gtfsRailTripShapeSQL = `
SELECT
  st.trip_id,
  'R:' || split_part(st.trip_id, ':', 1) || ':' ||
    md5(string_agg(st.stop_id, '>' ORDER BY st.stop_sequence)) AS shape_id
FROM ` + _gtfsStopTimeTable + ` st
LEFT JOIN ` + _gtfsStopTable + ` s ON s.stop_id = st.stop_id
WHERE st.trip_id LIKE 'TRA:%' OR st.trip_id LIKE 'THSR:%'
GROUP BY st.trip_id
HAVING count(*) > 1 AND count(*) = count(s.stop_id)`

var _gtfsRailShapePointsSQL = `
SELECT
  leg.shape_id,
  ST_Y(p.geom)::numeric(9,6) AS shape_pt_lat,
  ST_X(p.geom)::numeric(9,6) AS shape_pt_lon,
  (ROW_NUMBER() OVER (PARTITION BY leg.shape_id ORDER BY leg.leg_no, p.path[1]))::int
    AS shape_pt_sequence
FROM (
  SELECT
    s.shape_id,
    ROW_NUMBER() OVER (PARTITION BY s.shape_id ORDER BY s.stop_sequence) AS leg_no,
    COALESCE(
      g.geom,
      ST_MakeLine(ST_SetSRID(ST_MakePoint(a.stop_lon, a.stop_lat), 4326),
                  ST_SetSRID(ST_MakePoint(b.stop_lon, b.stop_lat), 4326))) AS geom
  FROM (
    SELECT r.shape_id, st.stop_sequence, st.stop_id AS from_stop,
           LEAD(st.stop_id) OVER (PARTITION BY r.shape_id ORDER BY st.stop_sequence) AS to_stop
    FROM (
      SELECT DISTINCT ON (shape_id) shape_id, trip_id
      FROM ` + _gtfsRailTripShapeTable + `
      ORDER BY shape_id, trip_id
    ) r
    JOIN ` + _gtfsStopTimeTable + ` st ON st.trip_id = r.trip_id
  ) s
  JOIN ` + _gtfsStopTable + ` a ON a.stop_id = s.from_stop
  JOIN ` + _gtfsStopTable + ` b ON b.stop_id = s.to_stop
  LEFT JOIN ` + _gtfsRailSegTable + ` g
    ON g.from_stop = s.from_stop AND g.to_stop = s.to_stop
  WHERE s.to_stop IS NOT NULL
) leg
CROSS JOIN LATERAL ST_DumpPoints(leg.geom) p
WHERE (leg.leg_no = 1 OR p.path[1] > 1)
  AND ST_Y(p.geom) BETWEEN 21 AND 26.5
  AND ST_X(p.geom) BETWEEN 118 AND 122.5`
