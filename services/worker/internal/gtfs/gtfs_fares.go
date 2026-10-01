package gtfs

// GTFS fare files (Fares v2): areas, stop_areas, fare_products, fare_leg_rules
// and the per-network fare tables they price from. Split out of gtfs_files.go
// for size; that file documents the identifier scheme every statement assumes.

const (
	_gtfsStopTable       = "gtfs_stop"
	_gtfsStopTimeTable   = "gtfs_stop_time"
	_gtfsFareSrcTable    = "gtfs_fare_src"
	_gtfsStopUIDTable    = "gtfs_stop_uid"
	_gtfsStopSeqTable    = "gtfs_stop_seq"
	_gtfsFarePairTable   = "gtfs_fare_pair"
	_gtfsFareLegTable    = "gtfs_fare_leg"
	_gtfsFarePricedTable = "gtfs_fare_priced"
	_gtfsFareZoneTable   = "gtfs_fare_zone"
)

const _gtfsFareODSQL = `
  SELECT 'MRT:' || f.system AS network_id,
         f.system || ':' || f.originstationid AS from_stop,
         f.system || ':' || f.destinationstationid AS to_stop,
         MIN((t.value->>'Price')::int) AS amount
  FROM raw_tdx.metro_odfare f
  CROSS JOIN LATERAL jsonb_array_elements(f.fares) t
  WHERE jsonb_typeof(f.fares) = 'array'
    AND COALESCE(f.originstationid, '') <> ''
    AND COALESCE(f.destinationstationid, '') <> ''
    AND (t.value->>'TicketType')::int = 1
    AND (t.value->>'FareClass')::int = 1
    AND (t.value->>'Price') ~ '^[0-9]+$'
  GROUP BY 1, 2, 3
  UNION ALL
  SELECT 'THSR',
         'THSR:' || f.originstationid,
         'THSR:' || f.destinationstationid,
         MIN((t.value->>'Price')::int)
  FROM raw_tdx.thsr_odfare f
  CROSS JOIN LATERAL jsonb_array_elements(f.fares) t
  WHERE jsonb_typeof(f.fares) = 'array'
    AND COALESCE(f.originstationid, '') <> ''
    AND COALESCE(f.destinationstationid, '') <> ''
    AND (t.value->>'TicketType')::int = 1
    AND (t.value->>'FareClass')::int = 1
    AND (t.value->>'Price') ~ '^[0-9]+$'
  GROUP BY 1, 2, 3
  UNION ALL
  SELECT 'TRA',
         'TRA:' || f.originstationid,
         'TRA:' || f.destinationstationid,
         MIN((t.value->>'Price')::int)
  FROM raw_tdx.tra_odfare f
  CROSS JOIN LATERAL jsonb_array_elements(f.fares) t
  WHERE jsonb_typeof(f.fares) = 'array'
    AND COALESCE(f.originstationid, '') <> ''
    AND COALESCE(f.destinationstationid, '') <> ''
    AND t.value->>'TicketType' = '成復'
    AND (t.value->>'Price') ~ '^[0-9]+$'
  GROUP BY 1, 2, 3`

var _gtfsFarePricedSQL = `
  WITH leg AS (
    SELECT network_id, from_stop, to_stop, amount FROM (` + _gtfsFareODSQL + `) rail
    UNION ALL
    SELECT network_id, from_uid, to_uid, amount
    FROM ` + _gtfsFareLegTable + ` bus
    WHERE from_uid IS NOT NULL AND to_uid IS NOT NULL
  )
  SELECT leg.network_id,
         'A:' || leg.from_stop AS from_area_id,
         'A:' || leg.to_stop AS to_area_id,
         leg.amount
  FROM leg
  WHERE leg.amount > 0
    AND leg.from_stop <> leg.to_stop
    AND leg.from_stop IN (SELECT stop_id FROM ` + _gtfsStopTable + `)
    AND leg.to_stop   IN (SELECT stop_id FROM ` + _gtfsStopTable + `)`

// _gtfsFareFlatSQL prices the routes that charge one fare however far the rider
// goes. Both area fields empty is Fares v2's way of saying "any leg on this
// network".
var _gtfsFareFlatSQL = `
  SELECT network_id, '' AS from_area_id, '' AS to_area_id, amount
  FROM ` + _gtfsFareLegTable + ` flat
  WHERE from_uid IS NULL AND amount >= 0`

// _gtfsFareZoneSQL is busSectionZoneSQL restricted to stops the feed emits, so a
// zone that survives has something in it.
var _gtfsFareZoneSQL = `
  SELECT z.routeuid, z.unit, z.stop_uid, z.idx
  FROM (` + _busSectionZoneSQL + `) z
  WHERE z.stop_uid IN (SELECT stop_id FROM ` + _gtfsStopTable + `)`

var _gtfsFareZoneMembersSQL = `
  SELECT DISTINCT 'Z:' || z.routeuid || ':' || z.idx::text AS area_id, z.stop_uid AS stop_id
  FROM ` + _gtfsFareZoneTable + ` z`

var _gtfsFareZoneRulesSQL = `
  WITH zone AS (SELECT DISTINCT routeuid, unit, idx FROM ` + _gtfsFareZoneTable + ` z)
  SELECT 'BUS:' || a.routeuid AS network_id,
         'Z:' || a.routeuid || ':' || a.idx::text AS from_area_id,
         'Z:' || a.routeuid || ':' || b.idx::text AS to_area_id,
         ` + busSectionUnitsSQL("a.idx", "b.idx") + ` * a.unit AS amount
  FROM zone a
  JOIN zone b ON b.routeuid = a.routeuid AND b.idx >= a.idx`

// busSectionUnitsSQL is how many section fares a leg from one zone index to
// another costs. Pulled out of the query so TestGTFSSectionFareUnits can
// evaluate the same expression the feed does rather than a copy of it.
func busSectionUnitsSQL(from, to string) string {
	return `(GREATEST(` + to + ` / 2 - (` + from + ` + 1) / 2, 0) + 1)`
}

// _gtfsFareAllRulesSQL is every priced leg: per-pair, sectioned and flat alike.
var _gtfsFareAllRulesSQL = `
  SELECT network_id, from_area_id, to_area_id, amount FROM ` + _gtfsFarePricedTable + ` p
  UNION ALL
  SELECT network_id, from_area_id, to_area_id, amount FROM (` + _gtfsFareZoneRulesSQL + `) z
  UNION ALL
  SELECT network_id, from_area_id, to_area_id, amount FROM (` + _gtfsFareFlatSQL + `) f`

// _gtfsAreasSQL declares every fare area: one per priced stop, plus one per
// section zone.
var _gtfsAreasSQL = `
WITH priced AS (SELECT * FROM ` + _gtfsFarePricedTable + `)
SELECT DISTINCT area_id, '' AS area_name
FROM (
  SELECT from_area_id AS area_id FROM priced
  UNION
  SELECT to_area_id FROM priced
  UNION
  SELECT area_id FROM (` + _gtfsFareZoneMembersSQL + `) z
) x
ORDER BY area_id`

var _gtfsStopAreasSQL = `
WITH area AS (
  SELECT from_area_id AS area_id FROM ` + _gtfsFarePricedTable + `
  UNION
  SELECT to_area_id FROM ` + _gtfsFarePricedTable + `
)
SELECT area.area_id, s.stop_id
FROM area
JOIN ` + _gtfsStopTable + ` s
  ON s.stop_id IN (substring(area.area_id from 3),
                   substring(area.area_id from 3) || ':platform')
UNION
SELECT area_id, stop_id FROM (` + _gtfsFareZoneMembersSQL + `) z
ORDER BY area_id, stop_id`

const _busFareSourceSQL = `
  SELECT f.city, f.routeid, NULL::text AS from_id, NULL::text AS to_id, 0 AS amount
  FROM raw_tdx.bus_routefare f
  WHERE COALESCE(f.isfreebus, 0) = 1
  UNION ALL
  -- A section fare with no buffer zone anywhere is one section, so one price.
  SELECT f.city, f.routeid, NULL, NULL, MIN((p.value->>'Price')::int)
  FROM raw_tdx.bus_routefare f
  CROSS JOIN LATERAL jsonb_array_elements(f.sectionfares) e
  CROSS JOIN LATERAL jsonb_array_elements(e.value->'Fares') p
  WHERE jsonb_typeof(f.sectionfares) = 'array'
    AND jsonb_typeof(e.value->'Fares') = 'array'
    AND COALESCE(f.isfreebus, 0) <> 1
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(f.sectionfares) z
      WHERE jsonb_typeof(z.value->'BufferZones') = 'array'
        AND jsonb_array_length(z.value->'BufferZones') > 0
    )
    AND ` + _busFareAdultSQL + `
  GROUP BY 1, 2
  UNION ALL
  SELECT f.city, f.routeid,
         e.value->'OriginStop'->>'StopID',
         e.value->'DestinationStop'->>'StopID',
         MIN((p.value->>'Price')::int)
  FROM raw_tdx.bus_routefare f
  CROSS JOIN LATERAL jsonb_array_elements(f.odfares) e
  CROSS JOIN LATERAL jsonb_array_elements(e.value->'Fares') p
  WHERE jsonb_typeof(f.odfares) = 'array'
    AND jsonb_typeof(e.value->'Fares') = 'array'
    AND COALESCE(e.value->'OriginStop'->>'StopID', '') <> ''
    AND COALESCE(e.value->'DestinationStop'->>'StopID', '') <> ''
    AND ` + _busFareAdultSQL + `
  GROUP BY 1, 2, 3, 4
  UNION ALL
  SELECT f.city, f.routeid,
         e.value->'OriginStage'->>'StopID',
         e.value->'DestinationStage'->>'StopID',
         MIN((p.value->>'Price')::int)
  FROM raw_tdx.bus_routefare f
  CROSS JOIN LATERAL jsonb_array_elements(f.stagefares) e
  CROSS JOIN LATERAL jsonb_array_elements(e.value->'Fares') p
  WHERE jsonb_typeof(f.stagefares) = 'array'
    AND jsonb_typeof(e.value->'Fares') = 'array'
    AND COALESCE(e.value->'OriginStage'->>'StopID', '') <> ''
    AND COALESCE(e.value->'DestinationStage'->>'StopID', '') <> ''
    AND ` + _busFareAdultSQL + `
  GROUP BY 1, 2, 3, 4`

const _busStopSeqSQL = `
    SELECT r.city, r.subrouteuid, COALESCE(r.direction, 0) AS direction,
           s->>'StopUID' AS stop_uid, s->>'StopID' AS stop_id,
           (s->>'StopSequence')::int AS seq
    FROM raw_tdx.bus_stopofroute r
    CROSS JOIN LATERAL jsonb_array_elements(r.stops) s
    WHERE jsonb_typeof(r.stops) = 'array'
      AND COALESCE(s->>'StopUID', '') <> ''
      AND (s->>'StopSequence') ~ '^[0-9]+$'`

const _busSectionZoneSQL = `
  WITH rec AS (
    SELECT f.city, f.routeid, f.subrouteid,
           MIN((p.value->>'Price')::int) AS unit,
           e.value->'BufferZones' AS zones
    FROM raw_tdx.bus_routefare f
    CROSS JOIN LATERAL jsonb_array_elements(f.sectionfares) e
    CROSS JOIN LATERAL jsonb_array_elements(e.value->'Fares') p
    WHERE jsonb_typeof(f.sectionfares) = 'array'
      AND jsonb_typeof(e.value->'BufferZones') = 'array'
      AND jsonb_array_length(e.value->'BufferZones') > 0
      AND jsonb_typeof(e.value->'Fares') = 'array'
      AND COALESCE(f.isfreebus, 0) <> 1
      AND ` + _busFareAdultSQL + `
    GROUP BY 1, 2, 3, 5
  ), sub AS (
    SELECT DISTINCT r.city, r.routeuid,
           s->>'SubRouteID' AS subrouteid, s->>'SubRouteUID' AS subrouteuid
    FROM raw_tdx.bus_route r
    CROSS JOIN LATERAL jsonb_array_elements(r.subroutes) s
    WHERE jsonb_typeof(r.subroutes) = 'array'
      AND COALESCE(s->>'SubRouteID', '') <> ''
      AND COALESCE(s->>'SubRouteUID', '') <> ''
  ), buffer AS (
    SELECT sub.routeuid, sub.subrouteuid, o.direction, rec.unit,
           o.seq AS lo, d.seq AS hi
    FROM rec
    JOIN sub ON sub.city = rec.city AND sub.subrouteid = rec.subrouteid
    CROSS JOIN LATERAL jsonb_array_elements(rec.zones) z
    JOIN ` + _gtfsStopSeqTable + ` o ON o.city = rec.city AND o.subrouteuid = sub.subrouteuid
                AND o.direction = (z.value->>'Direction')::int
                AND o.stop_id = z.value->'FareBufferZoneOrigin'->>'StopID'
    JOIN ` + _gtfsStopSeqTable + ` d ON d.city = rec.city AND d.subrouteuid = sub.subrouteuid
                AND d.direction = o.direction
                AND d.stop_id = z.value->'FareBufferZoneDestination'->>'StopID'
    WHERE o.seq <= d.seq
  ), zoned AS (
    SELECT b.routeuid, b.unit, s.stop_uid,
           2 * count(*) FILTER (WHERE b.hi < s.seq)
             + CASE WHEN count(*) FILTER (WHERE s.seq BETWEEN b.lo AND b.hi) > 0
                    THEN 1 ELSE 0 END AS idx
    FROM buffer b
    JOIN ` + _gtfsStopSeqTable + ` s ON s.subrouteuid = b.subrouteuid AND s.direction = b.direction
    GROUP BY b.routeuid, b.unit, b.subrouteuid, b.direction, s.stop_uid, s.seq
  ), conflict AS (
    -- A stop landing on two indices means two subroutes or two directions of one
    -- route disagree about which section it is in, and a GTFS area carries
    -- neither. 10,077 of 153,801 bus stops nationally serve both directions, so
    -- this is a real case rather than a defensive one. The route is dropped
    -- whole: pricing the half that agrees would quote some legs and not others
    -- on the same route, which reads as "this leg is free".
    SELECT DISTINCT routeuid FROM (
      SELECT routeuid, stop_uid FROM zoned GROUP BY 1, 2 HAVING count(DISTINCT idx) > 1
    ) c
    UNION
    SELECT routeuid FROM zoned GROUP BY routeuid HAVING count(DISTINCT unit) > 1
  )
  SELECT z.routeuid, z.unit, z.stop_uid, z.idx
  FROM zoned z
  WHERE z.routeuid NOT IN (SELECT routeuid FROM conflict)`

// _busFareAdultSQL pins the rider axis to the full adult single, the same axis
// the rail fares pin. FareClass 1 is 全票 in every bus pricing type; the classes
// beside it are 半票 and the concession tiers.
const _busFareAdultSQL = `(p.value->>'TicketType')::int = 1
    AND (p.value->>'FareClass')::int = 1
    AND (p.value->>'Price') ~ '^[0-9]+$'`

// _busStopUIDSQL maps TDX's city-local StopID to the StopUID stop_times
// references. It is materialized (gtfsTempTables) because the fare legs join to
// it twice, once per endpoint, over 1.8M rows.
const _busStopUIDSQL = `
    SELECT DISTINCT r.city, s->>'StopID' AS stop_id, s->>'StopUID' AS stop_uid
    FROM raw_tdx.bus_stopofroute r
    CROSS JOIN LATERAL jsonb_array_elements(r.stops) s
    WHERE jsonb_typeof(r.stops) = 'array'
      AND COALESCE(s->>'StopID', '') <> ''
      AND COALESCE(s->>'StopUID', '') <> ''`

var _busFarePairSQL = `
  WITH route AS (
    -- The same route set gtfsRoutesSQL's bus branch emits, and for the same
    -- reason it has to be: a fare naming a route routes.txt dropped is a leg
    -- rule on a network no route belongs to, which is an invalid feed. Kept in
    -- step by TestGTFSFaresAreConsistent rather than by hope.
    SELECT DISTINCT ON (r.city, r.routeid) r.city, r.routeid, r.routeuid
    FROM raw_tdx.bus_route r
    WHERE COALESCE(TRIM(r.routeuid), '') <> ''
      AND jsonb_typeof(r.operators) = 'array'
      AND COALESCE(r.operators->0->>'OperatorID', '') <> ''
      AND COALESCE(TRIM(COALESCE(NULLIF(r.routename->>'Zh_tw', ''), r.routeid)), '') <> ''
    ORDER BY r.city, r.routeid, r.updatetime DESC NULLS LAST
  )
  SELECT route.routeuid, fu.stop_uid AS from_uid, tu.stop_uid AS to_uid, src.amount
  FROM ` + _gtfsFareSrcTable + ` src
  JOIN route ON route.city = src.city AND route.routeid = src.routeid
  LEFT JOIN ` + _gtfsStopUIDTable + ` fu ON fu.city = src.city AND fu.stop_id = src.from_id
  LEFT JOIN ` + _gtfsStopUIDTable + ` tu ON tu.city = src.city AND tu.stop_id = src.to_id
  -- A pair whose stops do not resolve prices nothing, and keeping it would
  -- make the route look flat when it is not.
  WHERE (src.from_id IS NULL) = (fu.stop_uid IS NULL)
    AND (src.to_id IS NULL) = (tu.stop_uid IS NULL)`

var _busFareLegSQL = `
  WITH flat AS (
    SELECT routeuid, MIN(amount) AS amount
    FROM ` + _gtfsFarePairTable + `
    GROUP BY routeuid
    HAVING COUNT(DISTINCT amount) = 1
  )
  SELECT 'BUS:' || routeuid AS network_id, NULL::text AS from_uid, NULL::text AS to_uid, amount
  FROM flat
  UNION ALL
  SELECT 'BUS:' || p.routeuid, p.from_uid, p.to_uid, p.amount
  FROM ` + _gtfsFarePairTable + ` p
  WHERE p.from_uid IS NOT NULL AND p.to_uid IS NOT NULL
    AND p.routeuid NOT IN (SELECT routeuid FROM flat)
  UNION ALL
  -- The mirrored half: a Fares v2 leg rule is directional and TDX prices one
  -- direction of most bus pairs, so without this a rider travelling the other
  -- way along the same route matches no rule and is quoted nothing. On the
  -- 2026-08-06 feed that was 89.7% of the 1,637,421 priced pairs.
  --
  -- Where TDX priced the reverse itself it is left alone — the source is the
  -- better authority on its own fare. Where it did not, the outbound price is
  -- assumed to hold: of the pairs priced both ways, 90% agree. The other 10% are
  -- the cost of this, and it is a deliberate trade of some wrong prices for a
  -- feed that can price a return journey at all.
  SELECT 'BUS:' || p.routeuid, p.to_uid, p.from_uid, p.amount
  FROM ` + _gtfsFarePairTable + ` p
  WHERE p.from_uid IS NOT NULL AND p.to_uid IS NOT NULL
    AND p.routeuid NOT IN (SELECT routeuid FROM flat)
    AND NOT EXISTS (
      SELECT 1 FROM ` + _gtfsFarePairTable + ` x
      WHERE x.routeuid = p.routeuid AND x.from_uid = p.to_uid AND x.to_uid = p.from_uid
    )`

var _gtfsFareProductsSQL = `
SELECT DISTINCT
  'P:' || amount::text AS fare_product_id,
  '' AS fare_product_name,
  -- TWD's minor unit is two digits, and GTFS wants an amount written to its
  -- currency's precision: 20 is rejected where 20.00 is read as NT$20. The id
  -- keeps the integer spelling — it is opaque, and fare_leg_rules names it.
  to_char(amount, 'FM999999990.00') AS amount,
  'TWD' AS currency
FROM (` + _gtfsFareAllRulesSQL + `) p
ORDER BY fare_product_id`

var _gtfsFareLegRulesSQL = `
SELECT network_id, from_area_id, to_area_id, 'P:' || amount::text AS fare_product_id
FROM (` + _gtfsFareAllRulesSQL + `) r
ORDER BY network_id, from_area_id, to_area_id`
