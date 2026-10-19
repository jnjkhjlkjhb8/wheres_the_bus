package mrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// mrtStation decodes a TDX Rail/Metro/Station element used for the metro static
// station table.

// mrtFirstlast decodes a TDX Rail/Metro/FirstLastTimetable element: first/last
// train times per station, line, and destination for a weekly service pattern.

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
	if !validHHMMShape(s) {
		return 0, false
	}
	allDigits := validHHMMDigits(s)
	if !allDigits {
		return 0, false
	}
	return hhmmMinutes(s)
}

func validHHMMShape(s string) bool { return len(s) == 5 && s[2] == ':' }

func hhmmMinutes(s string) (int, bool) {
	// 24..29 are kept: TDX publishes past-midnight departures as hour 24+.
	h := int(s[0]-'0')*10 + int(s[1]-'0')
	m := int(s[3]-'0')*10 + int(s[4]-'0')
	if h > 29 || m > 59 {
		return 0, false
	}
	return h*60 + m, true
}

func validHHMMDigits(s string) bool {
	return isASCIIDigit(s[0]) && isASCIIDigit(s[1]) && isASCIIDigit(s[3]) && isASCIIDigit(s[4])
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
	if mrtWindowsCached() {
		return _mrtWindowCache.byKey
	}
	return reloadServiceWindows(ctx, db)
}

func mrtWindowsCached() bool {
	return _mrtWindowCache.byKey != nil && time.Since(_mrtWindowCache.loaded) < _mrtWindowCacheTTL
}

func reloadServiceWindows(ctx context.Context, db *pgxpool.Pool) map[string][]ServiceWindow {
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
	byKey, err := readServiceWindows(rows)
	if err != nil {
		zap.S().Errorw("scan error", "component", "mrt_eta", "action", "mrt_windows", "event", "scan_error", "err", err)
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

func readServiceWindows(rows pgx.Rows) (map[string][]ServiceWindow, error) {
	byKey := map[string][]ServiceWindow{}
	for rows.Next() {
		key, window, ok := readServiceWindow(rows)
		if ok {
			byKey[key] = append(byKey[key], window)
		}
	}
	return byKey, rows.Err()
}

func readServiceWindow(rows pgx.Rows) (string, ServiceWindow, bool) {
	var system, station, line, dest, ft, lt string
	if err := rows.Scan(&system, &station, &line, &dest, &ft, &lt); err != nil {
		return "", ServiceWindow{}, false
	}
	window, ok := parseServiceWindow(ft, lt)
	if !ok {
		return "", ServiceWindow{}, false
	}
	return WindowKey(system, station, line, dest), window, true
}

func parseServiceWindow(ft, lt string) (ServiceWindow, bool) {
	first, ok1 := parseHHMM(ft)
	last, ok2 := parseHHMM(lt)
	if !ok1 || !ok2 {
		return ServiceWindow{}, false
	}
	if last <= first {
		last += 24 * 60
	}
	return ServiceWindow{first: first, last: last}, true
}

func InService(windows map[string][]ServiceWindow, key string, now time.Time) bool {
	ws := windows[key]
	if len(ws) == 0 {
		return true
	}
	minutes := now.Hour()*60 + now.Minute()
	for _, w := range ws {
		if serviceWindowContains(w, minutes) {
			return true
		}
	}
	return false
}

func serviceWindowContains(w ServiceWindow, minutes int) bool {
	lo, hi := w.first-_mrtWindowGraceMin, w.last+_mrtWindowGraceMin
	// Clock times shortly after midnight can belong to the previous service day.
	return minuteInServiceRange(minutes, lo, hi) || minuteInServiceRange(minutes+24*60, lo, hi)
}

func minuteInServiceRange(value, lo, hi int) bool { return value >= lo && value <= hi }

func Eta(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink, db *pgxpool.Pool) error {
	zap.S().Infow("start", "component", "mrt_eta", "action", "mrt_eta", "event", "start")
	windows := ServiceWindows(ctx, db)
	now := time.Now().In(pipeline.Taipei)
	systems := []string{"TRTC", "KRTC", "KLRT", "TYMC"}
	var jobErr error
	for _, system := range systems {
		jobErr = errors.Join(jobErr, runMetroSystem(ctx, fetch, sink, system, windows, now))
	}
	zap.S().Infow("complete", "component", "mrt_eta", "action", "mrt_eta", "event", "complete")
	return jobErr
}

func runMetroSystem(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink, system string, windows map[string][]ServiceWindow, now time.Time) error {
	zap.S().Infow("system start", "component", "mrt_eta", "action", "mrt_eta", "system", system, "event", "system_start")
	result, err := fetch(ctx, fmt.Sprintf("/v2/Rail/Metro/LiveBoard/%s", system), "mrt_LiveBoard"+system)
	if err != nil {
		return _oops.With("system", system).Wrapf(err, "mrt fetch")
	}
	if !result.Modified {
		zap.S().Warnw("skip", "component", "mrt_eta", "action", "mrt_eta", "system", system, "event", "skip", "reason", "not_updated")
		return nil
	}
	return commitMetroSystem(ctx, sink, result, system, windows, now)
}

func commitMetroSystem(ctx context.Context, sink pipeline.LiveSink, result *shared.TDXFetch, system string, windows map[string][]ServiceWindow, now time.Time) error {
	filtered := 0
	processErr := pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error {
		return publishMetroSystem(ctx, sink, dec, system, windows, now, &filtered)
	})
	if processErr != nil {
		processErr = _oops.With("system", system).Wrapf(processErr, "mrt process")
	}
	if filtered > 0 {
		zap.S().Infow("out of service filtered", "component", "mrt_eta", "action", "mrt_eta", "system", system, "event", "out_of_service_filtered", "count", filtered)
	}
	return processErr
}

// TDX encodes TravelTime as either a number or a quoted string.

// TDX fare codes used by the metro ODFare feed.

// 單程票
// 全票
// 半票

// fares picks the single-journey full (全票) and half (半票) prices. A class the
// feed omits stays 0, which the upsert preserves rather than overwriting a known
// price with a zero.

// travelTimeMin parses an mrtODFare's optional whole-minute TravelTime. Missing
// values return zero; malformed, fractional, or negative values are errors.

/* optional */

// mrtLineTransfer decodes one TDX Rail/Metro/LineTransfer element: an interchange
// edge between two station IDs. TransferTime is whole minutes per the TDX schema.

// jsonNumInt parses a required whole-unit duration without silently converting
// malformed values to zero.

/* optional */

/* optional */

/* optional */

/* optional */

// UPDATE only rows that already exist (created by mrt_odfare); a pair absent
// from the matrix no-ops. Idx order is deterministic via the stations slice.

// round to nearest minute, floor 1

func publishMetroSystem(ctx context.Context, sink pipeline.LiveSink, dec *json.Decoder, system string, windows map[string][]ServiceWindow, now time.Time, filtered *int) error {
	pipe := sink.Pipe()
	ownedKeys := make([]string, 0)
	if err := pipeline.DecodeLiveItems(dec, func(temp mrtLive) error {
		return queueServiceMetro(pipe, temp, system, windows, now, filtered, &ownedKeys)
	}); err != nil {
		return err
	}
	pipe.ReplaceOwnedKeys(shared.LiveOwnedKeysKey("mrt", system), ownedKeys, pipeline.OwnedKeysTTL)
	if err := pipe.Exec(ctx); err != nil {
		return _oops.With("system", system).Wrapf(err, "publish MRT live board")
	}
	return nil
}

func queueServiceMetro(pipe pipeline.LivePipe, temp mrtLive, system string, windows map[string][]ServiceWindow, now time.Time, filtered *int, ownedKeys *[]string) error {
	if !InService(windows, WindowKey(system, temp.StationID, temp.LineID, temp.DestinationStaionID), now) {
		(*filtered)++
		return nil
	}
	return queueMetroArrival(pipe, temp, system, ownedKeys)
}

func queueMetroArrival(pipe pipeline.LivePipe, temp mrtLive, system string, ownedKeys *[]string) error {
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
	*ownedKeys = append(*ownedKeys, key)
	pipe.Publish(shared.MrtLiveChannel(system, temp.StationID), string(pb))
	return nil
}
