package predict

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/dmitryikh/leaves"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/holiday"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/weather"
	"go.uber.org/zap"
)

// RouteDirKey identifies one subroute Direction, used as a map key when batching
// next-departure and stop-offset lookups.
type RouteDirKey struct {
	SubRouteUID string
	Direction   int32
}

// StopOffsetKey identifies one stop's running-time offset from its subroute's
// origin: subroute, Direction, stop.
type StopOffsetKey struct {
	SubRouteUID string
	Direction   int32
	StopUID     string
}

// DedupRouteDirPairs removes duplicate route/Direction keys while preserving
// first-seen order, so the batched departure query does not repeat pairs.
func DedupRouteDirPairs(keys []RouteDirKey) []RouteDirKey {
	seen := make(map[RouteDirKey]bool, len(keys))
	out := make([]RouteDirKey, 0, len(keys))
	for _, k := range keys {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	return out
}

func BatchNextDepartures(ctx context.Context, db *pgxpool.Pool, keys []RouteDirKey, todTime string, dayBit int) map[RouteDirKey]time.Time {
	out := make(map[RouteDirKey]time.Time, len(keys))
	if len(keys) == 0 {
		return out
	}
	uids := make([]string, len(keys))
	dirs := make([]int32, len(keys))
	for i, k := range keys {
		uids[i] = k.SubRouteUID
		dirs[i] = k.Direction
	}
	rows, err := db.Query(ctx, `
		WITH wanted(sub_route_uid, Direction) AS (
			SELECT unnest($1::text[]), unnest($2::int[])
		),
		-- Per key rather than one DISTINCT ON over the whole join: a city's
		-- trips sorted together reach hundreds of thousands of rows and spill
		-- to disk, one subroute's fit in memory. TDX reuses a TripID within a
		-- subroute, so the departure time breaks ties toward the earlier trip.
		origin AS (
			SELECT w.sub_route_uid, w.Direction, o.dep
			FROM wanted w
			CROSS JOIN LATERAL (
				SELECT DISTINCT ON (b.tripid) b."arrival_time/StartTime" AS dep
				FROM bus_schedule b
				WHERE b.sub_route_uid = w.sub_route_uid AND b.Direction = w.Direction
				  AND b.type = false AND (b.service_day & $4) <> 0
				ORDER BY b.tripid, b.stopsequence, b."arrival_time/StartTime"
			) o
		)
		SELECT sub_route_uid, Direction, dep, 0 AS prio FROM (
			SELECT sub_route_uid, Direction, MIN(dep) AS dep
			FROM origin WHERE dep >= $3::time
			GROUP BY sub_route_uid, Direction
		) tt
		UNION ALL
		SELECT b.sub_route_uid, b.Direction,
		       MIN(GREATEST(b."arrival_time/StartTime", $3::time)) AS dep, 1 AS prio
		FROM bus_schedule b
		JOIN wanted w ON b.sub_route_uid = w.sub_route_uid AND b.Direction = w.Direction
		WHERE b.type = true AND (b.service_day & $4) <> 0
		  AND b."departure_time/EndTime" >= $3::time
		GROUP BY b.sub_route_uid, b.Direction`,
		uids, dirs, todTime, dayBit)
	if err != nil {
		zap.S().Errorw("BatchNextDepartures error", "component", "model", "err", err)
		return out
	}
	defer rows.Close()
	type prioDep struct {
		dep  time.Time
		prio int
	}
	best := make(map[RouteDirKey]prioDep, len(keys))
	for rows.Next() {
		var uid string
		var dir int32
		var dep time.Time
		var prio int
		if err := rows.Scan(&uid, &dir, &dep, &prio); err != nil {
			continue
		}
		k := RouteDirKey{SubRouteUID: uid, Direction: dir}
		if cur, ok := best[k]; !ok || prio < cur.prio {
			best[k] = prioDep{dep: dep, prio: prio}
		}
	}
	if err := rows.Err(); err != nil {
		zap.S().Errorw("BatchNextDepartures rows error", "component", "model", "err", err)
	}
	for k, v := range best {
		out[k] = v.dep
	}
	return out
}

func BatchStopOffsets(ctx context.Context, db *pgxpool.Pool, uids []string) map[StopOffsetKey]int {
	out := make(map[StopOffsetKey]int)
	if len(uids) == 0 {
		return out
	}
	missing := cachedStopOffsets(&_stopOffsetCache, uids, time.Now(), out)
	if len(missing) == 0 {
		return out
	}
	rows, err := db.Query(ctx, `
		SELECT p.sub_route_uid, p.Direction, p.stop_uid, p.offset_secs
		FROM (`+busmodel.PatternSQL+`) p
		WHERE p.complete AND p.sub_route_uid = ANY($1::text[])`,
		missing)
	if err != nil {
		zap.S().Errorw("BatchStopOffsets error", "component", "model", "err", err)
		return out
	}
	defer rows.Close()
	fetched := make(map[string][]stopOffset, len(missing))
	for _, uid := range missing {
		fetched[uid] = nil
	}
	for rows.Next() {
		var uid, stop string
		var dir int32
		var sec int
		if err := rows.Scan(&uid, &dir, &stop, &sec); err == nil {
			out[StopOffsetKey{SubRouteUID: uid, Direction: dir, StopUID: stop}] = sec
			fetched[uid] = append(fetched[uid], stopOffset{Direction: dir, StopUID: stop, secs: sec})
		}
	}
	if err := rows.Err(); err != nil {
		// A partial read is not cached: the uids it covered would look complete
		// and stay that way for the whole TTL.
		zap.S().Errorw("BatchStopOffsets rows error", "component", "model", "err", err)
		return out
	}
	storeStopOffsets(&_stopOffsetCache, fetched, time.Now())
	return out
}

// _predictor is the process-wide ETA model, built once at startup by
// newPredictor and never reassigned afterward. Tests that need a different
// model build their own local *predictor instead of mutating this one.
var _predictor *predictor

type predictor struct {
	model    *leaves.Ensemble
	encoders struct {
		City      map[string]int `json:"city"`
		PlateNumb map[string]int `json:"plate_numb"`
	}
}

func newPredictor() *predictor {
	path := os.Getenv("BUS_ETA_MODEL_PATH")
	if path == "" {
		path = "./model/bus_eta.json"
	}
	m, err := leaves.XGEnsembleFromFile(path, true /* loadTransformation */)
	if err != nil {
		zap.S().Infow("not loaded", "component", "model", "path", path, "err", err)
		return &predictor{}
	}
	p := &predictor{model: m}
	encPath := strings.TrimSuffix(path, ".json") + "_encoders.json"
	encData, err := os.ReadFile(encPath)
	if err != nil {
		zap.S().Infow("encoders not found", "component", "model", "path", encPath, "err", err)
	} else if err := json.Unmarshal(encData, &p.encoders); err != nil {
		zap.S().Infow("encoders parse failed", "component", "model", "path", encPath, "err", err)
	}
	zap.S().Infow("loaded", "component", "model", "path", path)
	return p
}

// StopCtx describes the stop being predicted: its subroute/Direction, the
// stop's position in the route (sequence out of total), and city.
type StopCtx struct {
	SubRouteUID  string
	Direction    int32
	StopUID      string
	City         string
	StopSequence int
	TotalStops   int
}

// Inputs carries the per-call inputs to prediction: the current time,
// the next scheduled departure, and the stop's running-time offset from the
// origin (its value, and whether one exists for this stop at all).
type Inputs struct {
	Now       time.Time
	NextDep   time.Time
	OffsetSec int
	HasOffset bool
}

func BaselineArrival(inputs Inputs) time.Time {
	if inputs.NextDep.IsZero() {
		return time.Time{}
	}
	t := inputs.Now.In(pipeline.Taipei)
	dep := time.Date(t.Year(), t.Month(), t.Day(),
		inputs.NextDep.Hour(), inputs.NextDep.Minute(), inputs.NextDep.Second(), 0, pipeline.Taipei)
	if !inputs.HasOffset {
		return dep
	}
	return dep.Add(time.Duration(inputs.OffsetSec) * time.Second)
}

func NextBusTime(wx *weather.Data, stop StopCtx, inputs Inputs) string {
	return _predictor.NextBusTime(wx, stop, inputs)
}

func (p *predictor) NextBusTime(wx *weather.Data, stop StopCtx, inputs Inputs) string {
	if p == nil || p.model == nil || inputs.NextDep.IsZero() {
		return ""
	}
	t := inputs.Now.In(pipeline.Taipei)
	dep := time.Date(t.Year(), t.Month(), t.Day(),
		inputs.NextDep.Hour(), inputs.NextDep.Minute(), inputs.NextDep.Second(), 0, pipeline.Taipei)
	if !inputs.HasOffset {
		return dep.Format(time.RFC3339)
	}
	ratio := 0.0
	if stop.TotalStops > 0 {
		ratio = float64(stop.StopSequence) / float64(stop.TotalStops)
	}
	// The caller passes the city's cached weather snapshot (read once per city
	// through the live sink); a nil snapshot leaves the features zero-valued.
	var wd weather.Data
	if wx != nil {
		wd = *wx
	}
	cityEnc := -1.0
	if v, ok := p.encoders.City[stop.City]; ok {
		cityEnc = float64(v)
	}
	features := []float64{
		float64(t.Hour()),
		float64(t.Weekday()),
		boolToFloat64(holiday.IsHoliday(t)),
		wd.Temperature,
		wd.Precipitation,
		wd.WindSpeed,
		wd.Humidity,
		float64(stop.Direction),
		float64(stop.StopSequence),
		float64(stop.TotalStops),
		ratio,
		cityEnc,
		-1,
		-1,
		-1,
	}
	correction := p.model.PredictSingle(features, 0)
	eta := dep.Add(time.Duration(inputs.OffsetSec)*time.Second + time.Duration(correction)*time.Second)
	return eta.Format(time.RFC3339)
}

// boolToFloat64 maps true to 1 and false to 0 for encoding a boolean feature
// (the holiday flag) into the model's float feature vector.
func boolToFloat64(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

// Install builds the process-wide ETA model and installs it as the one NextBusTime
// reads through. Called once at startup; a nil model leaves NextBusTime a no-op.
func Install() { _predictor = newPredictor() }
