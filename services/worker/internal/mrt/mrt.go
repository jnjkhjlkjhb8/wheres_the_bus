package mrt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// mrtStation decodes a TDX Rail/Metro/Station element used for the metro static
// station table.
type mrtStation struct {
	StationPosition struct {
		PositionLon float64 `json:"PositionLon"`
		PositionLat float64 `json:"PositionLat"`
	} `json:"StationPosition"`
	LocationCity       string `json:"LocationCity"`
	StationID          string `json:"StationID"`
	BikeAllowOnHoliday bool   `json:"BikeAllowOnHoliday"`
	StationName        struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"StationName"`
}

// mrtFirstlast decodes a TDX Rail/Metro/FirstLastTimetable element: first/last
// train times per station, line, and destination for a weekly service pattern.
type mrtFirstlast struct {
	LineID                 string `json:"LineID"`
	StationID              string `json:"StationID"`
	TripHeadSign           string `json:"TripHeadSign"`
	DestinationStaionID    string `json:"DestinationStaionID"`
	DestinationStationName struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"DestinationStationName"`
	FirstTrainTime string `json:"FirstTrainTime"`
	LastTrainTime  string `json:"LastTrainTime"`
	ServiceDay     struct {
		Monday           bool `json:"Monday"`
		Tuesday          bool `json:"Tuesday"`
		Wednesday        bool `json:"Wednesday"`
		Thursday         bool `json:"Thursday"`
		Friday           bool `json:"Friday"`
		Saturday         bool `json:"Saturday"`
		Sunday           bool `json:"Sunday"`
		NationalHolidays bool `json:"NationalHolidays"`
	} `json:"ServiceDay"`
}

type mrtLive struct {
	LineID                 string `json:"LineID"`
	StationID              string `json:"StationID"`
	TripHeadSign           string `json:"TripHeadSign"`
	DestinationStaionID    string `json:"DestinationStaionID"`
	DestinationStationName struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"DestinationStationName"`
	ServiceStatus uint8 `json:"ServiceStatus"`
	EstimateTime  int32 `json:"EstimateTime"`
}

func LoadStations(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt stations: system is required")
	}
	stations, err := pipeline.DecodeLoadArray[mrtStation](dec, "mrt stations "+system, func(_ int, station mrtStation) error {
		if strings.TrimSpace(station.StationID) == "" {
			return errors.New("StationID is required")
		}
		if !pipeline.ValidPosition(station.StationPosition.PositionLon, station.StationPosition.PositionLat) {
			return _oops.With("position_lon", station.StationPosition.PositionLon).With("position_lat", station.StationPosition.PositionLat).Errorf("position is invalid: lon= lat=")
		}
		return nil
	})
	if err != nil {
		return err
	}
	row := [][]any{}
	seen := make(map[string][]any, len(stations))
	for _, temp := range stations {
		g := fmt.Sprintf("POINT(%.6f %.6f)", temp.StationPosition.PositionLon, temp.StationPosition.PositionLat)
		candidate := []any{
			g,
			system,
			temp.StationName.ZhTw,
			temp.LocationCity,
			temp.StationID,
			temp.BikeAllowOnHoliday,
		}
		if err := pipeline.AppendUniqueLoadRow(&row, seen, system+"\x00"+temp.StationID, "station", candidate); err != nil {
			return _oops.With("system", system).Wrapf(err, "mrt stations")
		}
	}
	if len(row) == 0 {
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_station",
		CreateSQL: `CREATE TEMP TABLE temp_mrt (
					geom text,
					system text,
					name text,
					city text,
					id text,
					bike bool
				) ON COMMIT DROP;`,
		TempTable: "temp_mrt",
		CopyCols:  []string{"geom", "system", "name", "city", "id", "bike"},
		InsertSQL: `INSERT INTO mrt_station (
					stationposition,
					system,
					name,
					city,
					station_id,
					bikeallowonholiday,
					updated_at
				)
				SELECT st_geomfromtext(geom, 4326), system, name, city,id, bike,NOW() FROM temp_mrt
				ON CONFLICT (station_id,system) DO UPDATE SET name = EXCLUDED.name,city = excluded.city,stationposition = EXCLUDED.stationposition,bikeallowonholiday = EXCLUDED.bikeallowonholiday,updated_at = NOW();`,
	}, row)
}

func LoadFirstlast(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt first-last: system is required")
	}
	timetables, err := pipeline.DecodeLoadArray[mrtFirstlast](dec, "mrt first-last "+system, func(_ int, timetable mrtFirstlast) error {
		if strings.TrimSpace(timetable.StationID) == "" {
			return errors.New("StationID is required")
		}
		if strings.TrimSpace(timetable.LineID) == "" {
			return errors.New("LineID is required")
		}
		if strings.TrimSpace(timetable.DestinationStaionID) == "" {
			return errors.New("DestinationStaionID is required")
		}
		if v := strings.TrimSpace(timetable.FirstTrainTime); v != "" {
			if _, ok := parseHHMM(v); !ok {
				return _oops.With("first_train_time", timetable.FirstTrainTime).Errorf("FirstTrainTime is invalid")
			}
		}
		if v := strings.TrimSpace(timetable.LastTrainTime); v != "" {
			if _, ok := parseHHMM(v); !ok {
				return _oops.With("last_train_time", timetable.LastTrainTime).Errorf("LastTrainTime is invalid")
			}
		}
		if pipeline.Mask(timetable.ServiceDay.Monday, timetable.ServiceDay.Tuesday, timetable.ServiceDay.Wednesday,
			timetable.ServiceDay.Thursday, timetable.ServiceDay.Friday, timetable.ServiceDay.Saturday,
			timetable.ServiceDay.Sunday, timetable.ServiceDay.NationalHolidays) == 0 {
			return errors.New("ServiceDay must enable at least one day")
		}
		return nil
	})
	if err != nil {
		return err
	}
	row := [][]any{}
	for _, temp := range timetables {
		row = append(row, []any{
			temp.StationID,
			temp.LineID,
			temp.TripHeadSign,
			temp.DestinationStaionID,
			temp.DestinationStationName.ZhTw,
			temp.FirstTrainTime,
			temp.LastTrainTime,
			pipeline.Mask(temp.ServiceDay.Monday, temp.ServiceDay.Tuesday, temp.ServiceDay.Wednesday, temp.ServiceDay.Thursday, temp.ServiceDay.Friday, temp.ServiceDay.Saturday, temp.ServiceDay.Sunday, temp.ServiceDay.NationalHolidays),
			system,
		})
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key:     "mrt_firstlast",
		PreExec: []pipeline.CopyUpsertStmt{{SQL: `DELETE FROM mrt_schedule WHERE system = $1`, Args: []any{system}}},
		CreateSQL: `CREATE TEMP TABLE temp_mrt (
                               id text,
                               lid text,
							   sign text,
                               dsid text,
                               dsname text,
                               ft text,
                               lt text,
       						   mask int2,
       						   sys text
					) ON COMMIT DROP;`,
		TempTable: "temp_mrt",
		CopyCols:  []string{"id", "lid", "sign", "dsid", "dsname", "ft", "lt", "mask", "sys"},
		InsertSQL: `INSERT INTO mrt_schedule (
						station_id,
						lineid,
						destinationstaionid,
						destinationstationname,
						firsttraintime,
						lasttraintime,
						serviceday,
						system,
						created_at,
						updated_at,
						trip_head_sign
					)
					SELECT DISTINCT ON (id, lid, dsid, mask, sys)
						id,lid, dsid, dsname, ft, lt,mask,sys,NOW(),NOW(),sign FROM temp_mrt
					ORDER BY id, lid, dsid, mask, sys, ft, lt, dsname, sign`,
	}, row)
}

// ServiceWindow is one first/last-train window from mrt_schedule, in minutes
// since midnight; last exceeds 1440 when the last train runs past midnight.
type ServiceWindow struct {
	first, last int
}

// _mrtWindowGraceMin pads each service window: a train can legitimately appear on
// the live board a few minutes before the first departure and linger a few
// minutes after the station's last-train time.
const _mrtWindowGraceMin = 10

// _mrtWindowCacheTTL bounds how long the in-memory schedule windows are reused
// before re-reading mrt_schedule. The table only changes at the 03:30 daily
// load, so an hourly reload tracks it without a loader-side invalidation hook.
const _mrtWindowCacheTTL = time.Hour

var _mrtWindowCache struct {
	sync.Mutex
	loaded time.Time
	byKey  map[string][]ServiceWindow
}

func WindowKey(system, stationID, lineID, destStationID string) string {
	return system + "|" + stationID + "|" + lineID + "|" + destStationID
}

// parseHHMM parses "HH:MM" into minutes since midnight; ok is false for any
// other shape (mrt_schedule stores times as text straight from TDX).
func parseHHMM(s string) (int, bool) {
	if len(s) != 5 || s[2] != ':' {
		return 0, false
	}
	allDigits := isASCIIDigit(s[0]) && isASCIIDigit(s[1]) && isASCIIDigit(s[3]) && isASCIIDigit(s[4])
	if !allDigits {
		return 0, false
	}
	// 24..29 are kept: TDX publishes past-midnight departures as hour 24+.
	h := int(s[0]-'0')*10 + int(s[1]-'0')
	m := int(s[3]-'0')*10 + int(s[4]-'0')
	if h > 29 || m > 59 {
		return 0, false
	}
	return h*60 + m, true
}

func isASCIIDigit(b byte) bool {
	return b >= '0' && b <= '9'
}

func ServiceWindows(ctx context.Context, db *pgxpool.Pool) map[string][]ServiceWindow {
	if db == nil {
		return nil
	}
	_mrtWindowCache.Lock()
	defer _mrtWindowCache.Unlock()
	if _mrtWindowCache.byKey != nil && time.Since(_mrtWindowCache.loaded) < _mrtWindowCacheTTL {
		return _mrtWindowCache.byKey
	}
	rows, err := db.Query(ctx, `SELECT system, station_id, lineid, destinationstaionid, firsttraintime, lasttraintime FROM mrt_schedule`)
	if err != nil {
		zap.S().Errorw("query error",
			"component", "mrt_eta",
			"action", "mrt_windows",
			"event", "query_error",
			"err", err,
		)
		return _mrtWindowCache.byKey // stale beats none; nil on first failure
	}
	defer rows.Close()
	byKey := map[string][]ServiceWindow{}
	for rows.Next() {
		var system, station, line, dest, ft, lt string
		if err := rows.Scan(&system, &station, &line, &dest, &ft, &lt); err != nil {
			continue
		}
		first, ok1 := parseHHMM(ft)
		last, ok2 := parseHHMM(lt)
		if !ok1 || !ok2 {
			continue
		}
		if last <= first {
			last += 24 * 60 // last train past midnight belongs to the same service day
		}
		k := WindowKey(system, station, line, dest)
		byKey[k] = append(byKey[k], ServiceWindow{first: first, last: last})
	}
	if err := rows.Err(); err != nil {
		zap.S().Errorw("scan error",
			"component", "mrt_eta",
			"action", "mrt_windows",
			"event", "scan_error",
			"err", err,
		)
		return _mrtWindowCache.byKey
	}
	_mrtWindowCache.byKey = byKey
	_mrtWindowCache.loaded = time.Now()
	zap.S().Infow("reloaded",
		"component", "mrt_eta",
		"action", "mrt_windows",
		"event", "reloaded",
		"keys", len(byKey),
	)
	return byKey
}

func InService(windows map[string][]ServiceWindow, key string, now time.Time) bool {
	ws, ok := windows[key]
	if !ok || len(ws) == 0 {
		return true
	}
	minutes := now.Hour()*60 + now.Minute()
	for _, w := range ws {
		lo, hi := w.first-_mrtWindowGraceMin, w.last+_mrtWindowGraceMin
		// Check the same clock time on both the current and previous service
		// day, so 00:30 matches a 06:00–24:40 window via +24h.
		if (minutes >= lo && minutes <= hi) || (minutes+24*60 >= lo && minutes+24*60 <= hi) {
			return true
		}
	}
	return false
}

func Eta(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink, db *pgxpool.Pool) error {
	zap.S().Infow("start", "component", "mrt_eta", "action", "mrt_eta", "event", "start")
	windows := ServiceWindows(ctx, db)
	now := time.Now().In(pipeline.Taipei)
	systems := []string{"TRTC", "KRTC", "KLRT", "TYMC"}
	var jobErr error
	for _, system := range systems {
		filtered := 0
		zap.S().Infow("system start",
			"component", "mrt_eta",
			"action", "mrt_eta",
			"system", system,
			"event", "system_start",
		)
		result, err := fetch(ctx, fmt.Sprintf("/v2/Rail/Metro/LiveBoard/%s", system), "mrt_LiveBoard"+system)
		if err != nil {
			jobErr = errors.Join(jobErr, _oops.With("system", system).Wrapf(err, "mrt fetch"))
			continue
		}
		if !result.Modified {
			// A 304 has already refreshed the cached arrivals' TTL via pipeline.BoundFetch.
			zap.S().Warnw("skip",
				"component", "mrt_eta",
				"action", "mrt_eta",
				"system", system,
				"event", "skip",
				"reason", "not_updated",
			)
			continue
		}
		if err := pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error {
			pipe := sink.Pipe()
			ownedKeys := make([]string, 0)
			if err := pipeline.DecodeLiveItems(dec, func(temp mrtLive) error {
				if !InService(windows, WindowKey(system, temp.StationID, temp.LineID, temp.DestinationStaionID), now) {
					filtered++
					return nil
				}
				raw := &models.MrtLive{
					LineID:                 temp.LineID,
					StationID:              temp.StationID,
					System:                 system,
					TripHeadSign:           temp.TripHeadSign,
					DestinationStaionID:    temp.DestinationStaionID,
					DestinationStationName: temp.DestinationStationName.ZhTw,
					ServiceStatus:          int32(temp.ServiceStatus),
					EstimateTime:           temp.EstimateTime,
				}
				pb, err := proto.Marshal(raw)
				if err != nil {
					return err
				}
				key := shared.MrtLiveKey(system, temp.StationID, temp.LineID, temp.DestinationStaionID)
				pipe.Set(key, pb, pipeline.MrtLiveTTL)
				ownedKeys = append(ownedKeys, key)
				pipe.Publish(shared.MrtLiveChannel(system, temp.StationID), string(pb))
				return nil
			}); err != nil {
				return err
			}
			pipe.ReplaceOwnedKeys(shared.LiveOwnedKeysKey("mrt", system), ownedKeys, pipeline.OwnedKeysTTL)
			if err := pipe.Exec(ctx); err != nil {
				return _oops.With("system", system).Wrapf(err, "publish MRT live board")
			}
			return nil
		}); err != nil {
			jobErr = errors.Join(jobErr, _oops.With("system", system).Wrapf(err, "mrt process"))
		}
		if filtered > 0 {
			zap.S().Infow("out of service filtered",
				"component", "mrt_eta",
				"action", "mrt_eta",
				"system", system,
				"event", "out_of_service_filtered",
				"count", filtered,
			)
		}
	}
	zap.S().Infow("complete", "component", "mrt_eta", "action", "mrt_eta", "event", "complete")
	return jobErr
}

// TDX encodes TravelTime as either a number or a quoted string.
type mrtODFare struct {
	OriginStationID      string      `json:"OriginStationID"`
	DestinationStationID string      `json:"DestinationStationID"`
	TravelTime           json.Number `json:"TravelTime"`
	Fares                []struct {
		TicketType int `json:"TicketType"`
		FareClass  int `json:"FareClass"`
		Price      int `json:"Price"`
	} `json:"Fares"`
}

// TDX fare codes used by the metro ODFare feed.
const (
	_mrtTicketTypeSingle = 1 // 單程票
	_mrtFareClassFull    = 1 // 全票
	_mrtFareClassHalf    = 2 // 半票
)

// fares picks the single-journey full (全票) and half (半票) prices. A class the
// feed omits stays 0, which the upsert preserves rather than overwriting a known
// price with a zero.
func (f mrtODFare) fares() (full, half int) {
	for _, t := range f.Fares {
		if t.TicketType != _mrtTicketTypeSingle {
			continue
		}
		switch t.FareClass {
		case _mrtFareClassFull:
			full = t.Price
		case _mrtFareClassHalf:
			half = t.Price
		}
	}
	return full, half
}

// travelTimeMin parses an mrtODFare's optional whole-minute TravelTime. Missing
// values return zero; malformed, fractional, or negative values are errors.
func (f mrtODFare) travelTimeMin() (int, error) {
	value, err := nonNegativeJSONInteger(f.TravelTime, "TravelTime", true /* optional */, _maxPostgresInteger)
	if err != nil {
		return 0, err
	}
	return int(value), nil
}

func LoadJourneyMatrix(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt journey matrix: system is required")
	}
	fares, err := pipeline.DecodeLoadArray[mrtODFare](dec, "mrt journey matrix "+system, func(_ int, fare mrtODFare) error {
		if strings.TrimSpace(fare.OriginStationID) == "" {
			return errors.New("OriginStationID is required")
		}
		if strings.TrimSpace(fare.DestinationStationID) == "" {
			return errors.New("DestinationStationID is required")
		}
		if _, err := fare.travelTimeMin(); err != nil {
			return err
		}
		singleSeen := false
		classPrices := map[int]int{}
		for i, item := range fare.Fares {
			if item.TicketType <= 0 {
				return _oops.With("index", i).With("ticket_type", item.TicketType).Errorf("fares element TicketType must be positive")
			}
			if item.FareClass < 0 {
				return _oops.With("index", i).With("fare_class", item.FareClass).Errorf("fares element FareClass must be non-negative")
			}
			if item.Price < 0 {
				return _oops.With("index", i).With("price", item.Price).Errorf("fares element Price must be non-negative")
			}
			if item.TicketType == _mrtTicketTypeSingle {
				if item.FareClass == _mrtFareClassFull || item.FareClass == _mrtFareClassHalf {
					if prior, seen := classPrices[item.FareClass]; seen && prior != item.Price {
						return _oops.With("index", i).With("fare_class", item.FareClass).Errorf("fares element divergent duplicate TicketType 1 FareClass")
					}
					classPrices[item.FareClass] = item.Price
				}
				singleSeen = true
			}
		}
		if !singleSeen {
			return errors.New("fares must include TicketType 1")
		}
		return nil
	})
	if err != nil {
		return err
	}
	if len(fares) == 0 {
		return nil
	}
	rows := make([][]any, 0, len(fares))
	seen := make(map[string][]any, len(fares))
	for _, f := range fares {
		full, half := f.fares()
		travelTime, err := f.travelTimeMin()
		if err != nil {
			return _oops.With("system", system).Wrapf(err, "mrt journey matrix row build")
		}
		id := fmt.Sprintf("%s-%s-%s", system, f.OriginStationID, f.DestinationStationID)
		candidate := []any{id, f.OriginStationID, f.DestinationStationID, system, travelTime, full, half}
		key := system + "\x00" + f.OriginStationID + "\x00" + f.DestinationStationID
		if err := pipeline.AppendUniqueLoadRow(&rows, seen, key, "OD", candidate); err != nil {
			return _oops.With("system", system).Wrapf(err, "mrt journey matrix")
		}
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_journey_matrix",
		CreateSQL: `CREATE TEMP TABLE temp_mrt_journey_matrix (
			id text, from_station_id text, to_station_id text, system text,
			travel_time_min int, fare_nt int, half_fare_nt int
		) ON COMMIT DROP`,
		TempTable: "temp_mrt_journey_matrix",
		CopyCols:  []string{"id", "from_station_id", "to_station_id", "system", "travel_time_min", "fare_nt", "half_fare_nt"},
		InsertSQL: `INSERT INTO mrt_journey_matrix
			(id, from_station_id, to_station_id, system, travel_time_min, fare_nt, half_fare_nt, updated_at)
			SELECT id, from_station_id, to_station_id, system, travel_time_min, fare_nt, half_fare_nt, NOW()
			FROM temp_mrt_journey_matrix
			ON CONFLICT (from_station_id, to_station_id, system)
			DO UPDATE SET
				fare_nt = CASE WHEN EXCLUDED.fare_nt > 0
					THEN EXCLUDED.fare_nt ELSE mrt_journey_matrix.fare_nt END,
				half_fare_nt = CASE WHEN EXCLUDED.half_fare_nt > 0
					THEN EXCLUDED.half_fare_nt ELSE mrt_journey_matrix.half_fare_nt END,
				travel_time_min = CASE WHEN EXCLUDED.travel_time_min > 0
					THEN EXCLUDED.travel_time_min ELSE mrt_journey_matrix.travel_time_min END,
				updated_at = NOW()`,
	}, rows)
}

const _maxPostgresInteger int64 = 1<<31 - 1

func nonNegativeJSONInteger(number json.Number, field string, optional bool, maximum int64) (int64, error) {
	if number == "" {
		if optional {
			return 0, nil
		}
		return 0, _oops.With("field", field).Errorf("is required")
	}
	value, ok := new(big.Rat).SetString(number.String())
	if !ok || value.Sign() < 0 {
		return 0, _oops.With("field", field).With("number", number).Errorf("must be an exact non-negative number")
	}
	if !value.IsInt() {
		return 0, _oops.With("field", field).With("number", number).Errorf("must use whole units")
	}
	integer := value.Num()
	if !integer.IsInt64() || integer.Int64() > maximum {
		return 0, _oops.With("field", field).With("maximum", maximum).With("number", number).Errorf("must be between 0")
	}
	return integer.Int64(), nil
}

type mrtS2SRow struct {
	TravelTimes []struct {
		FromStationID string      `json:"FromStationID"`
		ToStationID   string      `json:"ToStationID"`
		RunTime       json.Number `json:"RunTime"`
		StopTime      json.Number `json:"StopTime"`
	} `json:"TravelTimes"`
}

// mrtLineTransfer decodes one TDX Rail/Metro/LineTransfer element: an interchange
// edge between two station IDs. TransferTime is whole minutes per the TDX schema.
type mrtLineTransfer struct {
	FromStationID string      `json:"FromStationID"`
	ToStationID   string      `json:"ToStationID"`
	TransferTime  json.Number `json:"TransferTime"`
}

// jsonNumInt parses a required whole-unit duration without silently converting
// malformed values to zero.
func jsonNumInt(n json.Number, field string) (int64, error) {
	value, err := nonNegativeJSONInteger(n, field, false /* optional */, _maxPostgresInteger)
	if err != nil {
		return 0, err
	}
	return value, nil
}

func LoadTrtcTravelTime(ctx context.Context, src pipeline.LoadSource, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt travel time: system is required")
	}
	s2sBody, _, err := src.DatasetJSON(ctx, "metro_s2straveltime", "system", system)
	if err != nil {
		return _oops.With("system", system).Wrapf(err, "mrt s2s read")
	}
	lines, err := pipeline.DecodeLoadArray[mrtS2SRow](json.NewDecoder(bytes.NewReader(s2sBody)), "mrt s2s "+system, func(_ int, line mrtS2SRow) error {
		for i, segment := range line.TravelTimes {
			if strings.TrimSpace(segment.FromStationID) == "" {
				return _oops.With("index", i).Errorf("TravelTimes element FromStationID is required")
			}
			if strings.TrimSpace(segment.ToStationID) == "" {
				return _oops.With("index", i).Errorf("TravelTimes element ToStationID is required")
			}
			runTime, err := nonNegativeJSONInteger(segment.RunTime, "RunTime", false /* optional */, _maxPostgresInteger)
			if err != nil {
				return _oops.With("index", i).Wrapf(err, "TravelTimes element")
			}
			if runTime == 0 {
				return _oops.With("index", i).Errorf("TravelTimes element: RunTime must be positive")
			}
			if _, err := nonNegativeJSONInteger(segment.StopTime, "StopTime", false /* optional */, _maxPostgresInteger); err != nil {
				return _oops.With("index", i).Wrapf(err, "TravelTimes element")
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	trBody, _, err := src.DatasetJSON(ctx, "metro_linetransfer", "system", system)
	if err != nil {
		return _oops.With("system", system).Wrapf(err, "mrt linetransfer read")
	}
	transfers, err := pipeline.DecodeLoadArray[mrtLineTransfer](json.NewDecoder(bytes.NewReader(trBody)), "mrt line transfer "+system, func(_ int, transfer mrtLineTransfer) error {
		if strings.TrimSpace(transfer.FromStationID) == "" {
			return errors.New("FromStationID is required")
		}
		if strings.TrimSpace(transfer.ToStationID) == "" {
			return errors.New("ToStationID is required")
		}
		transferTime, err := nonNegativeJSONInteger(transfer.TransferTime, "TransferTime", false /* optional */, _maxPostgresInteger)
		if err != nil {
			return err
		}
		if transferTime == 0 {
			return errors.New("TransferTime must be positive")
		}
		return nil
	})
	if err != nil {
		return err
	}

	stations, dist, segCount, transferCount, err := mrtTravelGraph(lines, transfers)
	if err != nil {
		return _oops.With("system", system).Wrapf(err, "mrt travel graph")
	}
	if len(stations) == 0 || segCount == 0 {
		zap.S().Infow("no graph",
			"component", "mrt",
			"action", "trtc_traveltime",
			"system", system,
			"event", "no_graph",
			"segments", segCount,
			"transfers", transferCount,
		)
		return nil
	}

	// UPDATE only rows that already exist (created by mrt_odfare); a pair absent
	// from the matrix no-ops. Idx order is deterministic via the stations slice.
	rows := make([][]any, 0, len(stations)*len(stations))
	for i, from := range stations {
		for j, to := range stations {
			if i == j {
				continue
			}
			d := dist[i][j]
			if d <= 0 || d >= _mrtGraphInf {
				continue
			}
			mins := max((d+30)/60, 1) // round to nearest minute, floor 1
			if mins > _maxPostgresInteger {
				return _oops.With("system", system).With("from", from).With("to", to).Errorf("mrt travel time to exceeds PostgreSQL integer maximum")
			}
			rows = append(rows, []any{mins, from, to, system})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_traveltime",
		CreateSQL: `CREATE TEMP TABLE temp_mrt_travel_time (
			travel_time_min int, from_station_id text, to_station_id text, system text
		) ON COMMIT DROP`,
		TempTable: "temp_mrt_travel_time",
		CopyCols:  []string{"travel_time_min", "from_station_id", "to_station_id", "system"},
		InsertSQL: `UPDATE mrt_journey_matrix AS matrix
			SET travel_time_min = fresh.travel_time_min, updated_at = NOW()
			FROM temp_mrt_travel_time AS fresh
			WHERE matrix.from_station_id = fresh.from_station_id
			  AND matrix.to_station_id = fresh.to_station_id
			  AND matrix.system = fresh.system`,
	}, rows)
}

type AdjacencyRow struct {
	LineID      string `json:"LineID"`
	TravelTimes []struct {
		FromStationID string `json:"FromStationID"`
		ToStationID   string `json:"ToStationID"`
	} `json:"TravelTimes"`
}

func LoadAdjacency(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt adjacency: system is required")
	}
	lines, err := pipeline.DecodeLoadArray[AdjacencyRow](dec, "mrt adjacency "+system, func(_ int, line AdjacencyRow) error {
		if strings.TrimSpace(line.LineID) == "" {
			return errors.New("LineID is required")
		}
		for i, seg := range line.TravelTimes {
			if strings.TrimSpace(seg.FromStationID) == "" {
				return _oops.With("index", i).Errorf("TravelTimes element FromStationID is required")
			}
			if strings.TrimSpace(seg.ToStationID) == "" {
				return _oops.With("index", i).Errorf("TravelTimes element ToStationID is required")
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	rows := AdjacencyRows(lines, system)
	if len(rows) == 0 {
		zap.S().Infow("no edges",
			"component", "mrt",
			"action", "mrt_adjacency",
			"system", system,
			"event", "no_edges",
		)
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_adjacency",
		CreateSQL: `CREATE TEMP TABLE temp_mrt_adjacency (
			system text, line_id text, from_station_id text, to_station_id text
		) ON COMMIT DROP`,
		TempTable: "temp_mrt_adjacency",
		CopyCols:  []string{"system", "line_id", "from_station_id", "to_station_id"},
		InsertSQL: `INSERT INTO mrt_adjacency (system, line_id, from_station_id, to_station_id, updated_at)
			SELECT system, line_id, from_station_id, to_station_id, NOW() FROM temp_mrt_adjacency
			ON CONFLICT (system, from_station_id, to_station_id)
			DO UPDATE SET line_id = EXCLUDED.line_id, updated_at = NOW()`,
	}, rows)
}

func AdjacencyRows(lines []AdjacencyRow, system string) [][]any {
	seen := map[string]bool{}
	var rows [][]any
	add := func(lineID, from, to string) {
		key := from + "\x00" + to
		if seen[key] {
			return
		}
		seen[key] = true
		rows = append(rows, []any{system, lineID, from, to})
	}
	for _, line := range lines {
		for _, seg := range line.TravelTimes {
			if seg.FromStationID == "" || seg.ToStationID == "" {
				continue
			}
			add(line.LineID, seg.FromStationID, seg.ToStationID)
			add(line.LineID, seg.ToStationID, seg.FromStationID)
		}
	}
	return rows
}

const _mrtGraphInf int64 = 1 << 62

func mrtTravelGraph(lines []mrtS2SRow, transfers []mrtLineTransfer) ([]string, [][]int64, int, int, error) {
	stations := []string{}
	idx := map[string]int{}
	id := func(s string) int {
		if i, ok := idx[s]; ok {
			return i
		}
		i := len(stations)
		idx[s] = i
		stations = append(stations, s)
		return i
	}
	type edge struct {
		a, b int
		w    int64
	}
	var edges []edge
	segCount, transferCount := 0, 0
	for _, ln := range lines {
		for _, s := range ln.TravelTimes {
			if s.FromStationID == "" || s.ToStationID == "" {
				continue
			}
			runTime, err := jsonNumInt(s.RunTime, "RunTime")
			if err != nil {
				return nil, nil, 0, 0, err
			}
			stopTime, err := jsonNumInt(s.StopTime, "StopTime")
			if err != nil {
				return nil, nil, 0, 0, err
			}
			edges = append(edges, edge{id(s.FromStationID), id(s.ToStationID), runTime + stopTime})
			segCount++
		}
	}
	for _, t := range transfers {
		if t.FromStationID == "" || t.ToStationID == "" {
			continue
		}
		transferTime, err := jsonNumInt(t.TransferTime, "TransferTime")
		if err != nil {
			return nil, nil, 0, 0, err
		}
		edges = append(edges, edge{id(t.FromStationID), id(t.ToStationID), transferTime * 60})
		transferCount++
	}
	n := len(stations)
	dist := make([][]int64, n)
	for i := range dist {
		dist[i] = make([]int64, n)
		for j := range dist[i] {
			if i != j {
				dist[i][j] = _mrtGraphInf
			}
		}
	}
	for _, e := range edges {
		if e.w < dist[e.a][e.b] {
			dist[e.a][e.b] = e.w
			dist[e.b][e.a] = e.w
		}
	}
	for k := range n {
		for i := range n {
			if dist[i][k] >= _mrtGraphInf {
				continue
			}
			for j := range n {
				if dist[k][j] >= _mrtGraphInf || dist[i][k] > _mrtGraphInf-dist[k][j] {
					continue
				}
				if d := dist[i][k] + dist[k][j]; d < dist[i][j] {
					dist[i][j] = d
				}
			}
		}
	}
	return stations, dist, segCount, transferCount, nil
}
