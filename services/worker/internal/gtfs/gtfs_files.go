package gtfs

import "github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"

const (
	// _gtfsTimezone and gtfsLang are the whole feed's; every agency is Taiwanese.
	_gtfsTimezone          = "Asia/Taipei"
	_gtfsLang              = "zh-TW"
	_gtfsFallbackAgencyURL = "https://tdx.transportdata.tw/"
	_gtfsNameZh            = "Zh_tw"
	_gtfsNameEn            = "En"
	// _gtfsTranslationLang is the language code translations.txt labels the
	// English rows with. GTFS wants an IETF tag, which 'En' is not.
	_gtfsTranslationLang = "en"
)

func gtfsPhoneSQL(column string) string {
	return `NULLIF(CASE WHEN length(regexp_replace(
		COALESCE((regexp_match(` + column + `, '[0-9()\- ]{8,}'))[1], ''),
		'[^0-9]', '', 'g')) BETWEEN 8 AND 11
	THEN regexp_replace(
		COALESCE((regexp_match(` + column + `, '[0-9()\- ]{8,}'))[1], ''),
		'[^0-9]', '', 'g') ELSE '' END, '')`
}

var _gtfsAgencySQL = gtfsAgencySQLFor(_gtfsNameZh)

func gtfsAgencySQLFor(lang string) string {
	return `
WITH rail AS (
  SELECT DISTINCT ON (operatorcode)
    operatorcode AS agency_id,
    operatorname->>'` + lang + `' AS agency_name,
    NULLIF(TRIM(operatorurl), '') AS agency_url,
    ` + gtfsPhoneSQL("operatorphone") + ` AS agency_phone
  FROM raw_tdx.rail_operator
  WHERE COALESCE(TRIM(operatorcode), '') <> ''
  ORDER BY operatorcode, providerid
), bus AS (
  SELECT
    city || ':' || operatorid AS agency_id,
    operatorname->>'` + lang + `' AS agency_name,
    NULLIF(TRIM(operatorurl), '') AS agency_url,
    ` + gtfsPhoneSQL("operatorphone") + ` AS agency_phone
  FROM raw_tdx.bus_operator
  WHERE COALESCE(TRIM(operatorid), '') <> '' AND COALESCE(TRIM(city), '') <> ''
)
SELECT
  agency_id,
  agency_name,
  COALESCE(agency_url, '` + _gtfsFallbackAgencyURL + `') AS agency_url,
  '` + _gtfsTimezone + `' AS agency_timezone,
  '` + _gtfsLang + `' AS agency_lang,
  COALESCE(agency_phone, '') AS agency_phone
FROM (SELECT * FROM rail UNION ALL SELECT * FROM bus) a
WHERE COALESCE(TRIM(agency_name), '') <> ''
ORDER BY agency_id`
}

var _gtfsStopsSQL = gtfsStopsSQLFor(_gtfsNameZh)

func gtfsStopsSQLFor(lang string) string {
	return `
WITH served AS (
  -- The stops some trip actually calls at. TDX's stop inventory is far larger
  -- than the operating network — bus_stopofroute lists every stop of every
  -- subroute, including those with no service on the landed day — and a stop no
  -- vehicle serves is not merely a validator warning: it enlarges the planner's
  -- spatial index and offers first-mile walks that lead nowhere.
  --
  -- Read out of the published calls, not the trip sources: a stop served only by
  -- a trip this feed rejects is still a stop with no service in it, and
  -- gtfsStopTimesSQL is where a trip is rejected. Reading the sources instead
  -- left 752 stops in the feed that nothing called at.
  --
  -- Rail and metro calls name a platform; a station is what is served. Bus stop
  -- ids carry no suffix and pass through untouched.
  SELECT DISTINCT regexp_replace(stop_id, ':platform$', '') AS ref
  FROM ` + _gtfsStopTimeTable + `
), rail_station AS (
  SELECT system AS sys, stationid AS sid, stationname->>'` + lang + `' AS nm,
         (stationposition->>'PositionLat')::double precision AS lat,
         (stationposition->>'PositionLon')::double precision AS lon
  FROM raw_tdx.metro_station
  WHERE stationposition ? 'PositionLat' AND stationposition ? 'PositionLon'
  UNION ALL
  SELECT 'TRA', stationid, stationname->>'` + lang + `',
         (stationposition->>'PositionLat')::double precision,
         (stationposition->>'PositionLon')::double precision
  FROM raw_tdx.tra_station
  WHERE stationposition ? 'PositionLat' AND stationposition ? 'PositionLon'
  UNION ALL
  SELECT 'THSR', stationid, stationname->>'` + lang + `',
         (stationposition->>'PositionLat')::double precision,
         (stationposition->>'PositionLon')::double precision
  FROM raw_tdx.thsr_station
  WHERE stationposition ? 'PositionLat' AND stationposition ? 'PositionLon'
), station_node AS (
  SELECT sys || ':' || sid AS stop_id, nm AS stop_name, lat AS stop_lat, lon AS stop_lon,
         1 AS location_type, '' AS parent_station
  FROM rail_station
  WHERE sys || ':' || sid IN (SELECT ref FROM served)
), platform_node AS (
  SELECT sys || ':' || sid || ':platform', nm, lat, lon, 0, sys || ':' || sid
  FROM rail_station
  WHERE sys || ':' || sid IN (SELECT ref FROM served)
), exit_source AS (
  -- key_name is always the Chinese name and exit_name is the one emitted. They
  -- differ only when this query is read in another language, and they have to:
  -- key_name decides both which rows reach exit_keyed and how the synthetic
  -- exit_key numbers them, so reading it in English would renumber entrances and
  -- produce stop_ids stops.txt has no row for.
  SELECT system AS sys, stationid AS sid,
         NULLIF(TRIM(exitid), '') AS exitid,
         COALESCE(NULLIF(exitname->>'` + _gtfsNameZh + `', ''), NULLIF(TRIM(exitid), '')) AS key_name,
         COALESCE(NULLIF(exitname->>'` + lang + `', ''), NULLIF(TRIM(exitid), '')) AS exit_name,
         (exitposition->>'PositionLat')::double precision AS lat,
         (exitposition->>'PositionLon')::double precision AS lon
  FROM raw_tdx.metro_stationexit
  WHERE exitposition ? 'PositionLat' AND exitposition ? 'PositionLon'
  UNION ALL
  SELECT 'THSR', stationid,
         NULLIF(TRIM(exitid), ''),
         COALESCE(NULLIF(exitname->>'` + _gtfsNameZh + `', ''), NULLIF(TRIM(exitid), '')),
         COALESCE(NULLIF(exitname->>'` + lang + `', ''), NULLIF(TRIM(exitid), '')),
         (exitposition->>'PositionLat')::double precision,
         (exitposition->>'PositionLon')::double precision
  FROM raw_tdx.thsr_stationexit
  WHERE exitposition ? 'PositionLat' AND exitposition ? 'PositionLon'
), exit_keyed AS (
  SELECT sys, sid, exit_name, lat, lon,
    COALESCE(exitid,
      'n' || ROW_NUMBER() OVER (PARTITION BY sys, sid ORDER BY key_name, lat, lon)) AS exit_key
  FROM exit_source
  WHERE COALESCE(key_name, '') <> ''
), exit_node AS (
  SELECT DISTINCT ON (e.sys, e.sid, e.exit_key)
    e.sys || ':' || e.sid || ':exit:' || e.exit_key, e.exit_name, e.lat, e.lon,
    2, e.sys || ':' || e.sid
  FROM exit_keyed e
  -- An entrance is kept only with its station, or its parent_station dangles.
  WHERE e.sys || ':' || e.sid IN (SELECT ref FROM served)
    AND EXISTS (SELECT 1 FROM rail_station s WHERE s.sys = e.sys AND s.sid = e.sid)
  ORDER BY e.sys, e.sid, e.exit_key
), bus_stop AS (
  SELECT DISTINCT ON (s->>'StopUID')
    s->>'StopUID',
    s->'StopName'->>'` + lang + `',
    (s->'StopPosition'->>'PositionLat')::double precision,
    (s->'StopPosition'->>'PositionLon')::double precision,
    0, ''
  FROM raw_tdx.bus_stopofroute r
  CROSS JOIN LATERAL jsonb_array_elements(r.stops) s
  WHERE COALESCE(s->>'StopUID', '') <> ''
    AND s->'StopPosition' ? 'PositionLat'
    AND s->'StopPosition' ? 'PositionLon'
    AND (s->>'StopUID') IN (SELECT ref FROM served)
  ORDER BY s->>'StopUID'
)
SELECT stop_id, stop_name, stop_lat, stop_lon, location_type, parent_station
FROM (
  SELECT * FROM station_node
  UNION ALL SELECT * FROM platform_node
  UNION ALL SELECT * FROM exit_node
  UNION ALL SELECT * FROM bus_stop
) s
WHERE COALESCE(TRIM(stop_name), '') <> ''
  AND stop_lat BETWEEN 21 AND 26.5
  AND stop_lon BETWEEN 118 AND 122.5
ORDER BY stop_id`
}

var _gtfsRoutesSQL = gtfsRoutesSQLFor(_gtfsNameZh)

func gtfsRoutesSQLFor(lang string) string {
	// The bus terminus names are columns, not jsonb keys, and THSR's route name
	// is a literal in both languages because TDX states it nowhere.
	thsrName, departure, destination := "高鐵", "departurestopnamezh", "destinationstopnamezh"
	if lang == _gtfsNameEn {
		thsrName, departure, destination = "THSR", "departurestopnameen", "destinationstopnameen"
	}
	return `
WITH metro AS (
  SELECT DISTINCT ON (r.system, r.routeid)
    r.system || ':' || r.routeid AS route_id,
    r.operatorcode AS agency_id,
    COALESCE(NULLIF(r.lineno, ''), r.routeid) AS route_short_name,
    r.routename->>'` + lang + `' AS route_long_name,
    CASE
      WHEN r.system IN ('KLRT', 'NTDLRT', 'NTALRT') THEN 0
      WHEN r.system = 'TRTCMG' THEN 6
      ELSE 1
    END AS route_type,
    LTRIM(COALESCE(l.linecolor, ''), '#') AS route_color,
    'MRT:' || r.system AS network_id
  FROM raw_tdx.metro_route r
  LEFT JOIN raw_tdx.metro_line l ON l.system = r.system AND l.lineid = r.lineid
  WHERE COALESCE(TRIM(r.routeid), '') <> ''
  ORDER BY r.system, r.routeid, r.direction
), tra AS (
  -- TRA routes are train types, not lines. A GTFS trip belongs to exactly one
  -- route, and TRA trains cross lines freely — a 自強 runs the 西部幹線 into the
  -- 南迴線 — so a line cannot be assigned per trip. DailyTrainInfo carries no
  -- LineID at all, only TrainTypeID, which every train has exactly one of.
  --
  -- The type set is derived from the timetable rather than from a train-type
  -- table so it cannot drift from the trips that reference it.
  --
  -- route_long_name stays empty: GTFS requires one of the two names, and
  -- repeating the type name in both trips route_long_name_contains_short_name.
  SELECT DISTINCT ON (dailytraininfo->>'TrainTypeID')
    'TRA:' || (dailytraininfo->>'TrainTypeID'),
    'TRA',
    dailytraininfo->'TrainTypeName'->>'` + lang + `',
    '', 2, '', 'TRA'
  FROM raw_tdx.tra_dailytimetable
  WHERE COALESCE(dailytraininfo->>'TrainTypeID', '') <> ''
    AND COALESCE(dailytraininfo->'TrainTypeName'->>'Zh_tw', '') <> ''
  ORDER BY dailytraininfo->>'TrainTypeID'
), thsr AS (
  -- 101 (extended: High Speed Rail Service), not the plain 2 TRA uses. Both
  -- would otherwise land on the same routing class -- nigiri maps 2 to
  -- kRegional and 101 to kHighSpeed (nigiri src/loader/gtfs/route.cc) -- and a
  -- planner filtered to 台鐵 would then return 高鐵 itineraries and vice versa.
  -- The distinction is the app's, exposed as two separate mode chips.
  SELECT 'THSR', 'THSR', '` + thsrName + `', '', 101, '', 'THSR'
), bus AS (
  SELECT DISTINCT ON (r.routeuid)
    r.routeuid AS route_id,
    r.city || ':' || (r.operators->0->>'OperatorID') AS agency_id,
    COALESCE(NULLIF(r.routename->>'` + lang + `', ''), r.routeid) AS route_short_name,
    CONCAT_WS('－',
      NULLIF(r.` + departure + `, ''),
      NULLIF(r.` + destination + `, '')) AS route_long_name,
    3 AS route_type,
    '' AS route_color,
    -- Every bus route is its own fare network: TDX prices buses per route, so
    -- two routes never share a fare rule. A network with no leg rule is a route
    -- whose fare is not known, which is the honest state for the 678 sectioned
    -- routes and anything TDX has no fare record for.
    'BUS:' || r.routeuid AS network_id
  FROM raw_tdx.bus_route r
  WHERE COALESCE(TRIM(r.routeuid), '') <> ''
    AND jsonb_typeof(r.operators) = 'array'
    AND COALESCE(r.operators->0->>'OperatorID', '') <> ''
  ORDER BY r.routeuid, r.updatetime DESC NULLS LAST
)
SELECT route_id, agency_id, route_short_name, route_long_name, route_type, route_color, network_id
FROM (
  SELECT * FROM metro
  UNION ALL SELECT * FROM tra
  UNION ALL SELECT * FROM thsr
  UNION ALL SELECT * FROM bus
) r
WHERE COALESCE(TRIM(route_short_name), '') <> ''
ORDER BY route_id`
}

var _gtfsTranslationsSQL = `
WITH a AS (` + gtfsAgencySQLFor(_gtfsNameEn) + `
), s AS (` + gtfsStopsSQLFor(_gtfsNameEn) + `
), r AS (` + gtfsRoutesSQLFor(_gtfsNameEn) + `
)
SELECT 'agency' AS table_name, 'agency_name' AS field_name,
       '` + _gtfsTranslationLang + `' AS language,
       agency_name AS translation, agency_id AS record_id
FROM a
UNION ALL
SELECT 'stops', 'stop_name', '` + _gtfsTranslationLang + `', stop_name, stop_id
FROM s
UNION ALL
SELECT 'routes', 'route_short_name', '` + _gtfsTranslationLang + `', route_short_name, route_id
FROM r
UNION ALL
-- route_long_name is optional and empty on the rail routes, where GTFS wants
-- exactly one of the two names set.
SELECT 'routes', 'route_long_name', '` + _gtfsTranslationLang + `', route_long_name, route_id
FROM r
WHERE COALESCE(TRIM(route_long_name), '') <> ''
ORDER BY 1, 2, 5`

var _gtfsPathwaysSQL = `
WITH stop AS (SELECT * FROM ` + _gtfsStopTable + `), entrance AS (
  SELECT stop_id, parent_station FROM stop WHERE location_type = 2
), flag AS (
  SELECT system || ':' || stationid || ':exit:' || TRIM(exitid) AS stop_id,
         COALESCE(stair, false) AS stair,
         COALESCE(escalator, 0) <> 0 AS escalator,
         COALESCE(elevator, false) AS elevator
  FROM raw_tdx.metro_stationexit
  WHERE COALESCE(TRIM(exitid), '') <> ''
  UNION ALL
  SELECT 'THSR:' || stationid || ':exit:' || TRIM(exitid),
         COALESCE(stair, false), COALESCE(escalator, false), COALESCE(elevator, false)
  FROM raw_tdx.thsr_stationexit
  WHERE COALESCE(TRIM(exitid), '') <> ''
)
SELECT 'PW:' || e.stop_id || ':' || m.mode::text AS pathway_id,
       e.stop_id AS from_stop_id,
       p.stop_id AS to_stop_id,
       m.mode AS pathway_mode,
       1 AS is_bidirectional
FROM entrance e
JOIN stop p ON p.stop_id = e.parent_station || ':platform'
LEFT JOIN flag f ON f.stop_id = e.stop_id
CROSS JOIN LATERAL (
  -- GTFS pathway_mode: 1 walkway, 2 stairs, 4 escalator, 5 elevator.
  SELECT 5 AS mode WHERE COALESCE(f.elevator, false)
  UNION ALL SELECT 4 WHERE COALESCE(f.escalator, false)
  UNION ALL SELECT 2 WHERE COALESCE(f.stair, false)
  UNION ALL SELECT 1 WHERE NOT (COALESCE(f.elevator, false)
                             OR COALESCE(f.escalator, false)
                             OR COALESCE(f.stair, false))
) m
ORDER BY pathway_id`

// _gtfsAttributionsSQL records where the data came from. TDX's terms require the
// source to be credited, so this file is a licensing obligation rather than a
// nicety, and it is a constant because there is exactly one source.
const _gtfsAttributionsSQL = `
SELECT
  'motc' AS attribution_id,
  '交通部運輸資料流通服務平臺 (TDX)' AS organization_name,
  0 AS is_producer,
  0 AS is_operator,
  1 AS is_authority,
  'https://tdx.transportdata.tw/' AS attribution_url`

func gtfsFeedInfoSQL(version string) string {
	return `
SELECT
  '我車呢' AS feed_publisher_name,
  'https://tdx.transportdata.tw/' AS feed_publisher_url,
  '` + _gtfsLang + `' AS feed_lang,
  'https://tdx.transportdata.tw/' AS feed_contact_url,
  ` + pipeline.SQLStringLiteral(version) + ` AS feed_version`
}
