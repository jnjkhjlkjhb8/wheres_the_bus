package vector

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/searchalias"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

// resp is one search_vector row on its way to the upsert, carried alongside
// the descriptive text its dataset builds. DepartSystem holds the departure stop for buses or the transit
// system for rail/metro.
type resp struct {
	Type         string
	UID          string
	Name         string
	City         string
	DepartSystem string
	Destin       string
	Geom         string
	postUpsert   []vectorWrite
}

type vectorWrite struct {
	sql  string
	args []any
}

// _cityNames maps a TDX city code to its Chinese display name, embedded into the
// search text so name queries match on locality.
var _cityNames = map[string]string{
	"Taipei": "台北市", "NewTaipei": "新北市", "Taoyuan": "桃園市",
	"Taichung": "台中市", "Tainan": "台南市", "Kaohsiung": "高雄市",
	"Keelung": "基隆市", "Hsinchu": "新竹市", "HsinchuCounty": "新竹縣",
	"MiaoliCounty": "苗栗縣", "ChanghuaCounty": "彰化縣", "NantouCounty": "南投縣",
	"YunlinCounty": "雲林縣", "ChiayiCounty": "嘉義縣", "Chiayi": "嘉義市",
	"PingtungCounty": "屏東縣", "YilanCounty": "宜蘭縣", "HualienCounty": "花蓮縣",
	"TaitungCounty": "台東縣", "PenghuCounty": "澎湖縣",
	"KinmenCounty": "金門縣", "LienchiangCounty": "連江縣",
	"InterCity": "公路客運",
	"Miaoli":    "苗栗縣", "Changhua": "彰化縣", "Nantou": "南投縣",
	"Yunlin": "雲林縣", "Pingtung": "屏東縣", "Yilan": "宜蘭縣",
	"Hualien": "花蓮縣", "Taitung": "台東縣", "Penghu": "澎湖縣",
	"Kinmen": "金門縣", "Lienchiang": "連江縣",
}

type mrtSystemLabel struct {
	code    string
	current string
	legacy  []string
}

// _mrtSystemLabels is the single source for both display labels and the SQL
// revision checks that invalidate vectors created with an older label mapping.
var _mrtSystemLabels = []mrtSystemLabel{
	{code: "TRTC", current: "台北捷運"},
	{code: "KRTC", current: "高雄捷運"},
	{code: "KLRT", current: "高雄輕軌", legacy: []string{"桃園捷運"}},
	{code: "TYMC", current: "桃園捷運", legacy: []string{"台中捷運"}},
	{code: "NTMC", current: "新北捷運", legacy: []string{"NTMC"}},
	{code: "NTDLRT", current: "淡海輕軌"},
	{code: "KHLRT", current: "高雄輕軌"},
	// Landed since the metro system sets widened to everything TDX serves.
	// New codes carry no legacy label: no vector was ever written for them, so
	// there is nothing to invalidate.
	{code: "TMRT", current: "台中捷運"},
	{code: "NTALRT", current: "安坑輕軌"},
	{code: "TRTCMG", current: "貓空纜車"},
}

// _mrtSystemNames maps a metro system code to its Chinese display name.
var _mrtSystemNames = func() map[string]string {
	names := make(map[string]string, len(_mrtSystemLabels))
	for _, label := range _mrtSystemLabels {
		names[label.code] = label.current
	}
	return names
}()

// cityName returns the Chinese display name for a city code, or the code itself
// when unmapped.
func cityName(code string) string {
	if n, ok := _cityNames[code]; ok {
		return n
	}
	return code
}

// mrtSystemName returns the Chinese display name for a metro system code, or the
// code itself when unmapped.
func mrtSystemName(code string) string {
	if n, ok := _mrtSystemNames[code]; ok {
		return n
	}
	return code
}

func mrtSystemNameSQL(systemExpr string) string {
	var sql strings.Builder
	sql.WriteString("CASE ")
	sql.WriteString(systemExpr)
	for _, label := range _mrtSystemLabels {
		sql.WriteString(" WHEN ")
		sql.WriteString(pipeline.SQLStringLiteral(label.code))
		sql.WriteString(" THEN ")
		sql.WriteString(pipeline.SQLStringLiteral(label.current))
	}
	sql.WriteString(" ELSE ")
	sql.WriteString(systemExpr)
	sql.WriteString(" END")
	return sql.String()
}

func mrtVectorSamePredicate(vectorAlias, stationAlias string) string {
	return fmt.Sprintf(
		"%[1]s.name = %[2]s.name AND %[1]s.city = %[3]s AND %[1]s.depart = %[2]s.system AND ST_OrderingEquals(%[1]s.geom, %[2]s.stationposition)",
		vectorAlias,
		stationAlias,
		mrtSystemNameSQL(stationAlias+".system"),
	)
}

func buildMRTStationsForVectorSQL() string {
	return `
	SELECT ms.station_id, ms.name, ms.system, ST_AsText(ms.stationposition)
	FROM mrt_station ms
	WHERE ms.updated_at < $1` + FreshVectorSkipSQL("mrt_station", "ms.station_id",
		mrtVectorSamePredicate("sv", "ms")) + `;`
}

func buildMRTLegacyVectorCleanupSQL() string {
	return fmt.Sprintf(`
	DELETE FROM search_vector stale_sv
	WHERE stale_sv.type = 'mrt_station'
	  AND stale_sv.uid = $1
	  AND stale_sv.city = $2
	  AND EXISTS (
	    SELECT 1
	    FROM mrt_station stale_ms
	    WHERE stale_ms.station_id = stale_sv.uid
	      AND stale_ms.system = $3
	  )
	  AND NOT EXISTS (
	    SELECT 1
	    FROM mrt_station keeper_ms
	    WHERE keeper_ms.station_id = stale_sv.uid
	      AND %s = stale_sv.city
	  );`, mrtSystemNameSQL("keeper_ms.system"))
}

func mrtLegacyVectorCleanupWrites(uid, system string) []vectorWrite {
	for _, label := range _mrtSystemLabels {
		if label.code != system {
			continue
		}
		writes := make([]vectorWrite, 0, len(label.legacy))
		for _, legacy := range label.legacy {
			writes = append(writes, vectorWrite{
				sql:  _mrtLegacyVectorCleanupSQL,
				args: []any{uid, legacy, system},
			})
		}
		return writes
	}
	return nil
}

const (
	// _size is the write batch size: rows are accumulated to this many
	// before one DB batch upsert.
	_size = 1024
)

type DB interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
	SendBatch(context.Context, *pgx.Batch) pgx.BatchResults
}

type Redis interface {
	Get(context.Context, string) *redis.StringCmd
	Set(context.Context, string, any, time.Duration) *redis.StatusCmd
}

var (
	_busSubroutesForVectorSQL = `
	SELECT bs.sub_route_uid, bs.sub_route_name, bs.city, bs.depart, bs.destin
	FROM bus_static bs
	WHERE bs.updated_at >= $1 AND bs.updated_at < $2` + FreshVectorSkipSQL("bus_route", "bs.sub_route_uid",
		"sv.name = bs.sub_route_name AND sv.depart = bs.depart AND sv.destin = bs.destin") + `;`
	_busStationsForVectorSQL = `
	SELECT bg.group_uid, bg.group_name, bg.city, ST_AsText(bg.position)
	FROM bus_station_groups bg
	WHERE bg.updated_at >= $1 AND bg.updated_at < $2` + FreshVectorSkipSQL("bus_station", "bg.group_uid",
		"sv.name = bg.group_name AND ST_OrderingEquals(sv.geom, bg.position)") + `;`
	_bikeStationsForVectorSQL = `
	SELECT bs.station_uid, bs.name, bs.city, ST_AsText(bs.geom)
	FROM bike_stations bs
	WHERE bs.updated_at >= $1 AND bs.updated_at < $2` + FreshVectorSkipSQL("bike_station", "bs.station_uid",
		"sv.name = bs.name AND ST_OrderingEquals(sv.geom, bs.geom)") + `;`
	_mrtStationsForVectorSQL   = buildMRTStationsForVectorSQL()
	_mrtLegacyVectorCleanupSQL = buildMRTLegacyVectorCleanupSQL()
	_traStationsForVectorSQL   = `
	SELECT ts.station_id, ts.name, ts.city, ST_AsText(ts.geom)
	FROM tra_stations ts
	WHERE ts.updated_at >= $1 AND ts.updated_at < $2` + FreshVectorSkipSQL("tra_station", "ts.station_id",
		"sv.name = ts.name AND ST_OrderingEquals(sv.geom, ts.geom)") + `;`
	_thsrStationsForVectorSQL = `
	SELECT ts.station_id, ts.name, ts.city, ST_AsText(ts.geom)
	FROM thsr_stations ts
	WHERE ts.updated_at >= $1 AND ts.updated_at < $2` + FreshVectorSkipSQL("thsr_station", "ts.station_id",
		"sv.name = ts.name AND ST_OrderingEquals(sv.geom, ts.geom)") + `;`
)

// vectorDataset keeps the query and its row processor together,
// preventing the registry order from drifting away from dataset-specific scan
// and text construction behavior.
type vectorDataset struct {
	key        string
	vectorType string
	query      string
	queryArgs  func(string, any) []any
	process    func(pgx.Rows) (string, resp, error)
}

func watermarkWindowQueryArgs(lower string, upper any) []any {
	return []any{lower, upper}
}

func upperCutoffQueryArgs(_ string, upper any) []any {
	return []any{upper}
}

var _vectorDatasets = []vectorDataset{
	{
		key:        "bus_subroutes",
		vectorType: "bus_route",
		query:      _busSubroutesForVectorSQL,
		queryArgs:  watermarkWindowQueryArgs,
		process: func(rows pgx.Rows) (string, resp, error) {
			var uid, name, city, depart, destin string
			if err := rows.Scan(&uid, &name, &city, &depart, &destin); err != nil {
				return "", resp{}, err
			}
			cn := cityName(city)
			text := fmt.Sprintf("類型：公車路線 子路線UID：%s 路線名：%s 縣市：%s 起點站：%s 終點站：%s", uid, name, cn, depart, destin)
			return text, resp{UID: uid, Name: name, City: cn, DepartSystem: depart, Destin: destin}, nil
		},
	},
	{
		key:        "bus_station_groups",
		vectorType: "bus_station",
		query:      _busStationsForVectorSQL,
		queryArgs:  watermarkWindowQueryArgs,
		process: func(rows pgx.Rows) (string, resp, error) {
			var uid, name, city, geom string
			if err := rows.Scan(&uid, &name, &city, &geom); err != nil {
				return "", resp{}, err
			}
			cn := cityName(city)
			text := fmt.Sprintf("類型：公車組站位 組站位UID：%s 組站位名稱：%s 縣市：%s 位置：%s", uid, name, cn, geom)
			return text, resp{UID: uid, Name: name, City: cn, Geom: geom}, nil
		},
	},
	{
		key:        "bike_stations",
		vectorType: "bike_station",
		query:      _bikeStationsForVectorSQL,
		queryArgs:  watermarkWindowQueryArgs,
		process: func(rows pgx.Rows) (string, resp, error) {
			var uid, name, city, geom string
			if err := rows.Scan(&uid, &name, &city, &geom); err != nil {
				return "", resp{}, err
			}
			cn := cityName(city)
			text := fmt.Sprintf("類型：公共自行車租借站 站點UID：%s 站點名稱：%s 縣市：%s 位置：%s", uid, name, cn, geom)
			return text, resp{UID: uid, Name: name, City: cn, Geom: geom}, nil
		},
	},
	{
		key:        "mrt_station",
		vectorType: "mrt_station",
		query:      _mrtStationsForVectorSQL,
		queryArgs:  upperCutoffQueryArgs,
		process: func(rows pgx.Rows) (string, resp, error) {
			var uid, name, system, geom string
			if err := rows.Scan(&uid, &name, &system, &geom); err != nil {
				return "", resp{}, err
			}
			cn := mrtSystemName(system)
			text := fmt.Sprintf("類型：捷運站 車站UID：%s 車站名稱：%s 捷運系統：%s 位置：%s", uid, name, cn, geom)
			return text, resp{
				UID:          uid,
				Name:         name,
				City:         cn,
				DepartSystem: system,
				Geom:         geom,
				postUpsert:   mrtLegacyVectorCleanupWrites(uid, system),
			}, nil
		},
	},
	{
		key:        "tra_stations",
		vectorType: "tra_station",
		query:      _traStationsForVectorSQL,
		queryArgs:  watermarkWindowQueryArgs,
		process: func(rows pgx.Rows) (string, resp, error) {
			var uid, name, city, geom string
			if err := rows.Scan(&uid, &name, &city, &geom); err != nil {
				return "", resp{}, err
			}
			cn := cityName(city)
			text := fmt.Sprintf("類型：台鐵車站 車站UID：%s 車站名稱：%s 縣市：%s 位置：%s", uid, name, cn, geom)
			return text, resp{UID: uid, Name: name, City: cn, Geom: geom}, nil
		},
	},
	{
		key:        "thsr_stations",
		vectorType: "thsr_station",
		query:      _thsrStationsForVectorSQL,
		queryArgs:  watermarkWindowQueryArgs,
		process: func(rows pgx.Rows) (string, resp, error) {
			var uid, name, city, geom string
			if err := rows.Scan(&uid, &name, &city, &geom); err != nil {
				return "", resp{}, err
			}
			cn := cityName(city)
			text := fmt.Sprintf("類型：高鐵車站 車站UID：%s 車站名稱：%s 縣市：%s 位置：%s", uid, name, cn, geom)
			return text, resp{UID: uid, Name: name, City: cn, Geom: geom}, nil
		},
	},
}

func FreshVectorSkipSQL(vectorType, uidExpr, samePredicate string) string {
	return fmt.Sprintf(`
	  AND NOT EXISTS (
	    SELECT 1
	    FROM search_vector sv
	    WHERE sv.type = '%s'
	      AND sv.uid = %s
	      AND sv.alias IS NOT NULL
	      AND %s
	  )`, vectorType, uidExpr, samePredicate)
}

// alias is derived from name here rather than being carried on resp: it is a
// pure function of the name (searchAlias), so computing it at the write is
// one place instead of one per dataset in _vectorDatasets.
const _searchVectorUpsertSQL = `INSERT INTO search_vector(
			type, uid, name, alias, city, depart, destin, geom, updated_at
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7,
			CASE WHEN $8 = '' THEN NULL ELSE ST_GeomFromText($8, 4326) END,
			NOW())
		ON CONFLICT (type, uid, city)
		DO UPDATE SET name = EXCLUDED.name,
			alias = EXCLUDED.alias,
			depart = EXCLUDED.depart,
			destin = EXCLUDED.destin,
			geom = EXCLUDED.geom,
			updated_at = NOW();`

func processVectorBatch(ctx context.Context, db DB, rows []resp) error {
	if len(rows) == 0 {
		return nil
	}
	batch := &pgx.Batch{}
	for _, row := range rows {
		batch.Queue(_searchVectorUpsertSQL,
			row.Type, row.UID, row.Name, searchalias.SearchAlias(row.Name), row.City,
			row.DepartSystem, row.Destin, row.Geom)
		for _, write := range row.postUpsert {
			batch.Queue(write.sql, write.args...)
		}
	}
	// With no transaction-control statements, pgx executes the batch in an
	// implicit transaction. A cleanup failure therefore rolls back its preceding
	// replacement upsert, and an upsert failure prevents its cleanup from running.
	if err := db.SendBatch(ctx, batch).Close(); err != nil {
		return _oops.Wrapf(err, "write vector batch")
	}
	return nil
}

func processVectorDataset(
	ctx context.Context,
	db DB,
	dataset vectorDataset,
	lower string,
	upper time.Time,
) error {
	rows, err := db.Query(ctx, dataset.query, dataset.queryArgs(lower, upper)...)
	if err != nil {
		return _oops.With("dataset_key", dataset.key).Wrapf(err, "query vector dataset")
	}
	defer rows.Close()

	metadata := make([]resp, 0, _size)
	for rows.Next() {
		_, row, err := dataset.process(rows)
		if err != nil {
			return _oops.With("dataset_key", dataset.key).Wrapf(err, "scan vector dataset")
		}
		row.Type = dataset.vectorType
		metadata = append(metadata, row)
		if len(metadata) == _size {
			if err := processVectorBatch(ctx, db, metadata); err != nil {
				return _oops.With("dataset_key", dataset.key).Wrapf(err, "process vector dataset")
			}
			metadata = metadata[:0]
		}
	}
	if err := rows.Err(); err != nil {
		return _oops.With("dataset_key", dataset.key).Wrapf(err, "read vector dataset rows")
	}
	if err := processVectorBatch(ctx, db, metadata); err != nil {
		return _oops.With("dataset_key", dataset.key).Wrapf(err, "process vector dataset")
	}
	return nil
}

// ChangeToVector refreshes every registered search-vector dataset inside one
// half-open watermark window. It advances LastTimeUpdate to the captured upper
// cutoff only after all queries, scans, and batch writes succeed.
func ChangeToVector(ctx context.Context, rc Redis, db DB) error {
	cutoff := time.Now().UTC()
	lower, err := rc.Get(ctx, "LastTimeUpdate").Result()
	if err != nil && !errors.Is(err, redis.Nil) {
		return _oops.Wrapf(err, "get vector watermark")
	}
	if lower == "" {
		lower = time.Time{}.Format(time.RFC3339)
	}

	for _, dataset := range _vectorDatasets {
		if err := processVectorDataset(ctx, db, dataset, lower, cutoff); err != nil {
			return err
		}
	}
	watermark := cutoff.Format(time.RFC3339Nano)
	if err := rc.Set(ctx, "LastTimeUpdate", watermark, 0).Err(); err != nil {
		return _oops.Wrapf(err, "set vector watermark")
	}
	zap.S().Infow("complete", "component", "vector", "action", "vector", "event", "complete", "cutoff", watermark)
	return nil
}
