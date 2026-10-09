package bus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"runtime/debug"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/holiday"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/weather"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// etaKey identifies one TDX ETA entry by its canonical subroute, derived
// direction, and stop. TDX emits one entry per (stop x subroute x direction),
// so keying on all three keeps multi-route stops from overwriting each other.
type etaKey struct {
	subRouteUID string
	direction   uint8
	stopUID     string
}

func busPositionIdentity(subRouteUID string, direction uint8) string {
	return fmt.Sprintf("%s\x00%d", subRouteUID, direction)
}

// _busPlatePassedStop is the value TDX sends in an N1 PlateNumb to say the
// vehicle has already passed that stop. It names no vehicle, so it must not
// reach the wire, an arrival push, or a history row's vehicle identity.
const _busPlatePassedStop = "-1"

func normalizeArrivalPlate(plate string) string {
	normalized := strings.ToUpper(strings.TrimSpace(plate))
	if normalized == _busPlatePassedStop {
		return ""
	}
	return normalized
}

const _busPositionMaxAge = 10 * time.Minute

// positionFresh reports whether a vehicle's GPS reading is recent enough to
// publish. An unparseable GPSTime (gpsTimeUnix 0) is kept: it carries no age to
// judge, and the app already renders it as 無定位.
func positionFresh(gpsTimeUnix int64, now time.Time) bool {
	if gpsTimeUnix == 0 {
		return true
	}
	return now.Sub(time.Unix(gpsTimeUnix, 0)) <= _busPositionMaxAge
}

func buildDirectionAwareBusPositionMap(city string, positions []busmodel.RawPosition, now time.Time) map[string][]*models.BusPosition {
	byIdentity := make(map[string][]*models.BusPosition)
	for _, position := range positions {
		gpsTimeUnix := parseGPSTimeUnix(position.GPSTime)
		if !positionFresh(gpsTimeUnix, now) {
			continue
		}
		uid, direction := shared.CanonicalSubroute(city, position.SubRouteUID, position.Direction)
		key := busPositionIdentity(uid, direction)
		byIdentity[key] = append(byIdentity[key], &models.BusPosition{
			PlateNumb:   position.PlateNumb,
			PositionLon: position.BusPosition.PositionLon,
			PositionLat: position.BusPosition.PositionLat,
			Speed:       int32(position.Speed),
			// Rounded, not truncated: the wire field is whole degrees, and a
			// fractional bearing is a real reading rather than a value with a
			// meaningful floor — 359.6° is north, not 359°.
			Azimuth:     int32(math.Round(position.Azimuth)),
			DutyStatus:  int32(position.DutyStatus),
			BusStatus:   int32(position.BusStatus),
			GpsTimeUnix: gpsTimeUnix,
			// Unset for every feed but Data.taipei's, which is what the wire enum's
			// zero value means (models/bus.proto).
			CrowdLevel: position.CrowdLevel,
		})
	}
	return byIdentity
}

// ArrivalNotifier receives each tick's arrival events: riderevent.Publisher in
// production, which hands them to rider for reminder dispatch.
type ArrivalNotifier interface {
	Arrivals(context.Context, []riderevent.ArrivalEvent) error
}

type busArrivalBatch struct {
	mu     sync.Mutex
	target ArrivalNotifier
	events []riderevent.ArrivalEvent
}

func (b *busArrivalBatch) Arrivals(_ context.Context, events []riderevent.ArrivalEvent) error {
	b.mu.Lock()
	b.events = append(b.events, events...)
	b.mu.Unlock()
	return nil
}

func (b *busArrivalBatch) flush(ctx context.Context) error {
	if b.target == nil {
		return nil
	}
	b.mu.Lock()
	events := append([]riderevent.ArrivalEvent(nil), b.events...)
	b.events = nil
	b.mu.Unlock()
	return b.target.Arrivals(ctx, events)
}

var _busEtaSkip = map[string]struct{}{
	"LienchiangCounty": {},
}

type vehicleSource interface {
	positions(context.Context) ([]busmodel.RawPosition, error)
}

type busLiveJob struct {
	fetch    pipeline.BoundFetch
	sink     pipeline.LiveSink
	store    busEtaStore
	notifier ArrivalNotifier
	vehicles map[string]vehicleSource
	eta      map[string]etaSource
	now      func() time.Time
	// snapshot is fixed for the whole run so every city lands on the same side
	// of the history sampling clock (see snapshotTick).
	snapshot      bool
	demandDataset string
}

const _busFeedCacheTTL = 10 * time.Minute

var errBusFeedCacheMiss = errors.New("bus raw feed cache missing")

func readBusFeedCache[T any](ctx context.Context, sink pipeline.LiveSink, key string) ([]T, error) {
	raw, err := sink.GetString(ctx, key)
	if errors.Is(err, redis.Nil) || (err == nil && raw == "") {
		return nil, _oops.With("key", key).Wrapf(errBusFeedCacheMiss, "bus feed cache lookup")
	}
	if err != nil {
		return nil, _oops.With("key", key).Wrapf(err, "read")
	}
	var values []T
	if err := json.Unmarshal([]byte(raw), &values); err != nil {
		return nil, _oops.With("key", key).Wrapf(err, "decode")
	}
	if values == nil {
		return nil, _oops.With("key", key).Wrapf(errBusFeedCacheMiss, "contains JSON null")
	}
	return values, nil
}

func pickBusEstimate(prev, next busmodel.RawEstimated) busmodel.RawEstimated {
	if prev.StopStatus == 0 && next.StopStatus == 0 {
		if next.EstimatedTime < prev.EstimatedTime {
			return next
		}
		return prev
	}
	if next.StopStatus == 0 {
		return next
	}
	return prev
}

func decodeBusEtaArray(dec *json.Decoder) (eat []busmodel.RawEstimated, err error) {
	eat = make([]busmodel.RawEstimated, 0)
	opening, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("read opening array token: %w", err)
	}
	if opening != json.Delim('[') {
		return nil, fmt.Errorf("body is not a JSON array: opens with %v", opening)
	}
	for dec.More() {
		var e busmodel.RawEstimated
		if err := dec.Decode(&e); err != nil {
			return eat, fmt.Errorf("decode element %d: %w", len(eat), err)
		}
		eat = append(eat, e)
	}
	closing, err := dec.Token()
	if err != nil {
		return eat, fmt.Errorf("read closing array token after %d elements: %w", len(eat), err)
	}
	if closing != json.Delim(']') {
		return eat, fmt.Errorf("array does not close after %d elements: got %v", len(eat), closing)
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return eat, fmt.Errorf("trailing data after array of %d elements: %v (err %w)", len(eat), trailing, err)
	}
	return eat, nil
}

var _busEtaFastCities = func() []string {
	fast := make([]string, 0, len(_dataTaipeiDynamicCities))
	for city := range _dataTaipeiDynamicCities {
		fast = append(fast, city)
	}
	sort.Strings(fast)
	return fast
}()

// _busEtaSlowCities is cities minus busEtaFastCities: every city still polled
// for ETA on the shared "@every 30s" TDX cadence.
var _busEtaSlowCities = func() []string {
	fast := make(map[string]struct{}, len(_dataTaipeiDynamicCities))
	for _, city := range _busEtaFastCities {
		fast[city] = struct{}{}
	}
	slow := make([]string, 0, len(busmodel.Cities))
	for _, city := range busmodel.Cities {
		if _, isFast := fast[city]; !isFast {
			slow = append(slow, city)
		}
	}
	return slow
}()

// Eta refreshes live bus arrivals for busEtaSlowCities on the 30s cron.
// Cities are processed concurrently, capped at 4 in flight (sem). It blocks
// until every city finishes.
func Eta(
	ctx context.Context,
	fetch pipeline.BoundFetch,
	sink pipeline.LiveSink,
	db *pgxpool.Pool,
	notifier ArrivalNotifier,
) error {
	return runBusEtaTick(ctx, "bus_eta", _busEtaSlowCities, history.BusEtaTickInterval,
		nil, nil, fetch, sink, db, notifier, "bus_eta")
}

func EtaFast(
	ctx context.Context,
	fetch pipeline.BoundFetch,
	sink pipeline.LiveSink,
	db *pgxpool.Pool,
	notifier ArrivalNotifier,
) error {
	// One feed per Data.taipei city, shared between the vehicle overlay and the
	// ETA override: both read the same blob container.
	vehicles := make(map[string]vehicleSource, len(_busEtaFastCities))
	etaFeeds := make(map[string]etaSource, len(_busEtaFastCities))
	for _, city := range _busEtaFastCities {
		feed := NewDataTaipeiFeed(city)
		vehicles[city] = feed
		etaFeeds[city] = feed
	}
	return runBusEtaTick(ctx, "bus_eta_fast", _busEtaFastCities, history.BusEtaFastTickInterval,
		vehicles, etaFeeds, fetch, sink, db, notifier, "")
}

// runBusEtaTick is the shared body of Eta and EtaFast: build the job,
// run cityList, log start/complete under component so the two crons are
// distinguishable in the logs.
func runBusEtaTick(
	ctx context.Context,
	component string,
	cityList []string,
	tickInterval time.Duration,
	vehicles map[string]vehicleSource,
	eta map[string]etaSource,
	fetch pipeline.BoundFetch,
	sink pipeline.LiveSink,
	db *pgxpool.Pool,
	notifier ArrivalNotifier,
	demandDataset string,
) error {
	zap.S().Infow("start", "component", component, "action", "Bus_eta", "event", "start")
	job := busLiveJob{
		fetch:    fetch,
		sink:     sink,
		store:    pgBusEtaStore{db: db},
		vehicles: vehicles,
		eta:      eta,
		now:      time.Now,
		snapshot: history.SnapshotTick(time.Now(), tickInterval),

		demandDataset: demandDataset,
	}
	jobErr := runBusEtaCities(ctx, cityList, &job, notifier)
	zap.S().Infow("complete", "component", component, "action", "Bus_eta", "event", "complete")
	return jobErr
}

func (j busLiveJob) runCityGuarded(ctx context.Context, city string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = _oops.With("rows", r).Errorf("panic")
			zap.S().Errorw("panic",
				"component", "bus_eta",
				"action", "Bus_eta",
				"city", city,
				"event", "panic",
				"value", r,
				"stack", debug.Stack(),
			)
		}
	}()
	return j.runCity(ctx, city)
}

func (j busLiveJob) shouldRunCity(ctx context.Context, city string) bool {
	if j.demandDataset == "" || j.snapshot {
		return true
	}
	return pipeline.LiveDemandGate(ctx, j.sink, j.demandDataset, city)
}

func runBusEtaCities(ctx context.Context, cityNames []string, job *busLiveJob, target ArrivalNotifier) error {
	arrivalBatch := &busArrivalBatch{target: target}
	job.notifier = arrivalBatch
	sem := make(chan struct{}, 4)
	errCh := make(chan error, len(cityNames))
	var wg sync.WaitGroup
	for _, city := range cityNames {
		if city == "ChanghuaCounty" || city == "NantouCounty" {
			continue
		}
		wg.Add(1)
		go func(city string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			if !job.shouldRunCity(ctx, city) {
				if err := job.sink.RefreshTTL(ctx, busEtaTTLPatterns(city)); err != nil {
					errCh <- _oops.With("city", city).Wrapf(err, "refresh unwatched bus ETA TTLs")
				}
				return
			}
			if err := job.runCityGuarded(ctx, city); err != nil {
				errCh <- _oops.With("city", city).Wrapf(err, "bus ETA city run")
			}
		}(city)
	}
	wg.Wait()
	close(errCh)
	var jobErr error
	for err := range errCh {
		jobErr = errors.Join(jobErr, err)
	}
	if err := arrivalBatch.flush(ctx); err != nil {
		jobErr = errors.Join(jobErr, _oops.Wrapf(err, "dispatch bus arrival reminders"))
	}
	return jobErr
}

func busEtaTTLPatterns(city string) []pipeline.TTLPattern {
	return []pipeline.TTLPattern{
		{Pattern: shared.BusStationEtaPattern(city), TTL: pipeline.BusLiveTTL},
		{Pattern: shared.BusRouteEtaPattern(busmodel.CityPrefix[city]), TTL: pipeline.BusLiveTTL},
	}
}

func (j busLiveJob) runCity(ctx context.Context, city string) (err error) {
	published := false
	defer func() {
		if err == nil || published || ctx.Err() != nil {
			return
		}
		if refreshErr := j.sink.RefreshTTL(ctx, busEtaTTLPatterns(city)); refreshErr != nil {
			err = errors.Join(err, refreshErr)
		}
	}()
	if _, skip := _busEtaSkip[city]; skip {
		return nil
	}
	zap.S().Infow("city start", "component", "bus_eta", "action", "Bus_eta", "city", city, "event", "city_start")
	prefix := busmodel.CityPrefix[city]
	if prefix == "" {
		zap.S().Warnw("skip empty",
			"component", "bus_eta",
			"action", "Bus_eta",
			"city", city,
			"event", "skip_empty",
			"reason", "no_prefix",
		)
		return nil
	}
	generation, generationErr := j.sink.GetString(ctx, shared.BusStaticGenerationKey(city))
	if generationErr != nil {
		// Redis is the cross-process signal, but an outage must not stop realtime
		// service. The local cache falls back to its bounded TTL in this case.
		generation = ""
	}
	mp, cached := predict.CachedStaticMapFrom(predict.StaticMapCache(), prefix, generation, j.now())
	if !cached {
		var err error
		mp, err = j.store.staticStops(ctx, prefix)
		if err != nil {
			return _oops.With("city", city).Wrapf(err, "load static stops")
		}
		if len(mp) == 0 {
			// No static stops yet (a city the loader has not landed): nothing to
			// resolve live ETA against, so skip the tick rather than fail it.
			zap.S().Warnw("skip empty",
				"component", "bus_eta",
				"action", "Bus_eta",
				"city", city,
				"event", "skip_empty",
				"reason", "no_stations",
			)
			return nil
		}
		predict.StoreStaticMapIn(predict.StaticMapCache(), prefix, mp, generation, j.now())
	}
	if len(mp) == 0 {
		zap.S().Warnw("skip empty",
			"component", "bus_eta",
			"action", "Bus_eta",
			"city", city,
			"event", "skip_empty",
			"reason", "no_stations",
		)
		return nil
	}
	var (
		eat      []busmodel.RawEstimated
		etaRaw   []byte
		etaFetch *shared.TDXFetch
	)
	etaModified := true
	if source, ok := j.eta[city]; ok {
		eat, err = source.estimates(ctx)
		if err != nil {
			return _oops.With("city", city).Wrapf(err, "fetch bus ETA")
		}
		etaRaw, err = json.Marshal(eat)
		if err != nil {
			return err
		}
	} else {
		etaURL := fmt.Sprintf("/v2/Bus/EstimatedTimeOfArrival/City/%s", city)
		if city == "InterCity" {
			etaURL = "/v2/Bus/EstimatedTimeOfArrival/InterCity"
		}
		etaFetch, err = j.fetch(ctx, etaURL, "bus_EstimatedTimeOfArrival"+city)
		if err != nil {
			return _oops.With("city", city).Wrapf(err, "fetch bus ETA")
		}
		etaModified = etaFetch.Modified
		if etaFetch.Modified {
			var decodeErr error
			eat, decodeErr = decodeBusEtaArray(etaFetch.Decoder)
			closeErr := etaFetch.Close()
			if decodeErr != nil {
				decodeErr = _oops.With("city", city).Wrapf(decodeErr, "decode bus ETA response")
			}
			if decodeErr != nil || closeErr != nil {
				return errors.Join(decodeErr, closeErr)
			}
			etaRaw, err = json.Marshal(eat)
			if err != nil {
				return err
			}
		}
	}

	posit := make([]busmodel.RawPosition, 0)
	positionURL := fmt.Sprintf("/v2/Bus/RealTimeByFrequency/City/%s", city)
	if city == "InterCity" {
		positionURL = "/v2/Bus/RealTimeByFrequency/InterCity"
	}
	positionFetch, err := j.fetch(ctx, positionURL, "bus_RealTimeByFrequency"+city)
	if err != nil {
		return _oops.With("city", city).Wrapf(err, "fetch bus positions")
	}
	var positionRaw []byte
	if positionFetch.Modified {
		decodeErr := pipeline.DecodeLiveItems(positionFetch.Decoder, func(p busmodel.RawPosition) error {
			posit = append(posit, p)
			return nil
		})
		closeErr := positionFetch.Close()
		if decodeErr != nil || closeErr != nil {
			return errors.Join(decodeErr, closeErr)
		}
		positionRaw, err = json.Marshal(posit)
		if err != nil {
			return err
		}
	}

	etaCacheKey := shared.BusETARawKey(city)
	positionCacheKey := shared.BusPositionRawKey(city)
	pipe := j.sink.Pipe()
	var cacheErr error
	if etaModified {
		pipe.Set(etaCacheKey, etaRaw, _busFeedCacheTTL)
	} else {
		eat, err = readBusFeedCache[busmodel.RawEstimated](ctx, j.sink, etaCacheKey)
		if err != nil {
			cacheErr = errors.Join(cacheErr, err)
		} else {
			pipe.Expire(etaCacheKey, _busFeedCacheTTL)
		}
	}
	if positionFetch.Modified {
		pipe.Set(positionCacheKey, positionRaw, _busFeedCacheTTL)
	} else {
		posit, err = readBusFeedCache[busmodel.RawPosition](ctx, j.sink, positionCacheKey)
		if err != nil {
			cacheErr = errors.Join(cacheErr, err)
		} else {
			pipe.Expire(positionCacheKey, _busFeedCacheTTL)
		}
	}

	if cacheErr != nil {
		execErr := pipe.Exec(ctx)
		var ackErr error
		if execErr == nil {
			// etaFetch is nil for a Data.taipei city (no TDX ETA fetch to
			// acknowledge or invalidate); etaModified is always true for one,
			// so neither branch below would otherwise skip it.
			if etaModified && etaFetch != nil {
				ackErr = errors.Join(ackErr, pipeline.AcknowledgeTDXFetch(etaFetch))
			}
			if positionFetch.Modified {
				ackErr = errors.Join(ackErr, pipeline.AcknowledgeTDXFetch(positionFetch))
			}
		}
		var invalidateErr error
		if etaFetch != nil && !etaModified {
			invalidateErr = errors.Join(invalidateErr, pipeline.InvalidateTDXFetch(etaFetch))
		}
		if !positionFetch.Modified {
			invalidateErr = errors.Join(invalidateErr, pipeline.InvalidateTDXFetch(positionFetch))
		}
		return errors.Join(cacheErr, execErr, ackErr, invalidateErr)
	}

	observed := etaModified || positionFetch.Modified

	stations := make(map[string]*models.Bus_StationArrival)
	routes := make(map[string]*models.Bus_RouteArrival)
	etamap := buildBusEtaMap(city, eat, mp)
	posit = j.overlayVehicles(ctx, city, posit)
	now := j.now().In(pipeline.Taipei)
	busmap := buildDirectionAwareBusPositionMap(city, posit, now)
	atStopMap := buildBusAtStopMap(city, posit)
	for key, presence := range j.nearStops(ctx, city, now) {
		atStopMap[key] = presence
	}
	totalStops := buildTotalStops(mp)
	var wx *weather.Data
	if wjson, wErr := j.sink.GetString(ctx, shared.WeatherKey(city)); wErr == nil {
		var w weather.Data
		if json.Unmarshal([]byte(wjson), &w) == nil {
			wx = &w
		}
	}
	isHoliday := holiday.IsHoliday(now)
	fillKeys, fillUIDs := collectFillKeys(mp, etamap)
	todTime := now.Format("15:04:05")
	// Day-of-week mask only; holiday-aware schedules would need TDX SpecialDays
	// landing, as schedule rows carry no holiday flag from TDX's Mon-Sun fields.
	dayBit := 1 << ((int(now.Weekday()) + 6) % 7) // mask2 bit order: Monday=bit0..Sunday=bit6
	depMap := j.store.nextDepartures(ctx, predict.DedupRouteDirPairs(fillKeys), todTime, dayBit)
	uidList := make([]string, 0, len(fillUIDs))
	for u := range fillUIDs {
		uidList = append(uidList, u)
	}
	offsetMap := j.store.stopOffsets(ctx, uidList)
	// baselineFor returns the schedule+running-time arrival for a stop, shared by
	// the delay-propagation observation pass and the downstream fill.
	baselineFor := func(b busmodel.StationMap, uid string, dir int32) time.Time {
		offsetSec, hasOffset := offsetMap[predict.StopOffsetKey{SubRouteUID: uid, Direction: dir, StopUID: b.StopUID}]
		return predict.BaselineArrival(predict.Inputs{
			Now:       now,
			NextDep:   depMap[predict.RouteDirKey{SubRouteUID: uid, Direction: dir}],
			OffsetSec: offsetSec,
			HasOffset: hasOffset,
		})
	}
	// Delay-propagation observation stage: record each en-route vehicle's delay
	// against the schedule+running-time baseline, keyed per route/direction, for
	// the downstream fill to inherit.
	upstreamByRoute := buildUpstreamObs(mp, etamap, now, baselineFor)
	var (
		predictionRows        []history.PredictionRecord
		historyRows           [][]any
		arrivalEvents         []riderevent.ArrivalEvent
		fillsWithoutDeparture int
	)
	for _, b := range mp {
		uid, dir := b.SubRouteUID, b.Direction
		positionKey := busPositionIdentity(uid, dir)
		eta, ok := etaForStop(etamap, b)
		status := _busEtaNoReading
		var est int32
		var stime string
		if ok {
			est = adjustedEstimate(eta, now)
			status = eta.StopStatus
			stime = eta.SrcUpdateTime
			if status == 0 && arrivingExpired(eta, now) {
				status = _busEtaNoReading
			}
		}
		// Resolved in the status==0 branch below (a live bus is only matched to the
		// stop when one is en route).
		var plateNumb *string
		if status == 0 {
			ts := totalStops[uid]
			var busSpeed *int16
			var busDist *int
			plateNumb, busSpeed, busDist = nearestBus(b.Lat, b.Lon, busmap[positionKey])
			if plate, speed, dist, ok := busAtStop(atStopMap, busAtStopKey{uid, dir, b.StopUID}); ok {
				plateNumb, busDist = plate, dist
				if speed != nil {
					busSpeed = speed
				}
			}
			if p := normalizeArrivalPlate(eta.PlateNumb); p != "" {
				plateNumb = &p
			}
			if history.RecordsHistory(est, j.snapshot) {
				var srcTime *time.Time
				if t, ok := parseSrcUpdateTime(stime); ok {
					srcTime = &t
				}
				var nextBusTimePtr *string
				if eta.NextBusTime != "" {
					nbtp := eta.NextBusTime
					nextBusTimePtr = &nbtp
				}
				// nil stays nil when the city has no weather reading: the history
				// columns are nullable and a zero would read as a real measurement.
				var weatherTemp, weatherPrecip, weatherWind, weatherHumid any
				if wx != nil {
					weatherTemp = wx.Temperature
					weatherPrecip = wx.Precipitation
					weatherWind = wx.WindSpeed
					weatherHumid = wx.Humidity
				}
				historyRows = append(historyRows, []any{
					uid, b.StopUID, int16(dir),
					int16(b.StopSequence), int16(ts), est, nextBusTimePtr, srcTime,
					city, int16(now.Hour()), int16(now.Weekday()), isHoliday,
					weatherTemp, weatherPrecip, weatherWind, weatherHumid,
					plateNumb, busSpeed, busDist, now,
				})
			}
		}
		if status == 1 && eta.NextBusTime == "" {
			rk := predict.RouteDirKey{SubRouteUID: uid, Direction: int32(dir)}
			if depMap[rk].IsZero() {
				fillsWithoutDeparture++
			}
			var predictedArrival time.Time
			var predSource string
			if propArrival, propOK := predict.PropagateDelay(
				baselineFor(b, uid, int32(dir)), int(b.StopSequence), upstreamByRoute[rk], now,
			); propOK {
				predictedArrival = propArrival
				predSource = history.SourcePropagation
				eta.NextBusTime = propArrival.Format(time.RFC3339)
			} else {
				offsetSec, hasOffset := offsetMap[predict.StopOffsetKey{SubRouteUID: uid, Direction: int32(dir), StopUID: b.StopUID}]
				eta.NextBusTime = predict.NextBusTime(wx,
					predict.StopCtx{
						SubRouteUID:  uid,
						Direction:    int32(dir),
						StopUID:      b.StopUID,
						City:         city,
						StopSequence: int(b.StopSequence),
						TotalStops:   totalStops[uid],
					},
					predict.Inputs{
						Now:       now,
						NextDep:   depMap[rk],
						OffsetSec: offsetSec,
						HasOffset: hasOffset,
					},
				)
				if eta.NextBusTime != "" {
					if t, err := time.Parse(time.RFC3339, eta.NextBusTime); err == nil {
						predictedArrival = t
						// Without an offset the model tier returns the bare departure
						// uncorrected, which is a schedule prediction rather than a
						// model one; label it as such so the two are measured apart.
						predSource = history.SourceSchedule
						if hasOffset {
							predSource = history.SourceModel
						}
					}
				}
			}
			// Record the prediction (actual pending) for daily MAE measurement.
			if predSource != "" && !predictedArrival.IsZero() {
				predictionRows = append(predictionRows, history.PredictionRecord{SubRouteUID: uid,
					Direction:     int16(dir),
					StopUID:       b.StopUID,
					Source:        predSource,
					PredictedAt:   now,
					PredictedSecs: int(predictedArrival.Sub(now).Round(time.Second).Seconds()),
				})
			}
		}
		groupUID := b.GroupUID
		if groupUID == "" {
			groupUID = b.StationUID
		}
		groupName := b.GroupName
		if groupName == "" {
			groupName = b.StationName
		}
		if _, exists := stations[groupUID]; !exists {
			stations[groupUID] = &models.Bus_StationArrival{
				StationName: groupName,
			}
		}
		arrivalUnix := computeArrivalUnix(status, est, eta.NextBusTime, now)
		station := stations[groupUID]
		if !slices.Contains(station.StationUid, b.StationUID) {
			station.StationUid = append(station.StationUid, b.StationUID)
		}
		station.Routes = append(station.Routes, &models.Bus_StopEstimate{
			StopUid:       b.StationUID,
			SubRouteUid:   uid,
			RouteName:     b.SubRouteName,
			Destination:   b.Destination,
			Direction:     int32(dir),
			Estimate:      est,
			NextBusTime:   eta.NextBusTime,
			StopStatus:    int32(status),
			SrcUpdateTime: stime,
			Buses:         busmap[positionKey],
			ArrivalUnix:   arrivalUnix,
			CrowdLevel:    crowdForPlate(busmap[positionKey], plateNumb),
			IsLastBus:     eta.IsLastBus == 1,
		})
		if shouldDispatchBusArrival(ok, status, est) {
			arrivalEvents = append(arrivalEvents, riderevent.ArrivalEvent{
				RouteType: "bus", RouteKey: uid, StopKey: b.StopUID,
				Direction: strconv.Itoa(int(dir)), ETASeconds: est,
				ArrivingPlate: normalizeArrivalPlate(eta.PlateNumb),
			})
		}
		if _, ok = routes[uid]; !ok {
			routes[uid] = &models.Bus_RouteArrival{
				SubRouteUid: uid,
			}
		}
		routes[uid].Stops = append(routes[uid].Stops, &models.Bus_RouteEstimate{
			StopUid:       b.StopUID,
			Direction:     int32(dir),
			Estimate:      est,
			StopStatus:    int32(status),
			NextBusTime:   eta.NextBusTime,
			SrcUpdateTime: stime,
			Buses:         busmap[positionKey],
			StopSequence:  int32(b.StopSequence),
			ArrivalUnix:   arrivalUnix,
			PlateNumb:     normalizeArrivalPlate(eta.PlateNumb),
			CrowdLevel:    crowdForPlate(busmap[positionKey], plateNumb),
			IsLastBus:     eta.IsLastBus == 1,
		})
	}
	for groupUID, pb := range stations {
		data, err := proto.Marshal(pb)
		if err != nil {
			return err
		}
		key := shared.BusStationEtaKey(city, groupUID)
		pipe.Set(key, data, pipeline.BusLiveTTL)
		pipe.Publish(key, data)
	}
	for uid, pb := range routes {
		data, err := proto.Marshal(pb)
		if err != nil {
			return err
		}
		key := shared.BusRouteEtaKey(uid)
		pipe.Set(key, data, pipeline.BusLiveTTL)
		pipe.Publish(key, data)
	}
	err = pipe.Exec(ctx)
	if err != nil {
		return _oops.With("city", city).With("stations", len(stations)).With("routes", len(routes)).With("eat", len(eat)).With("posit", len(posit)).Wrapf(err, "publish bus realtime snapshot for (stations= routes= eta= positions=)")
	}
	published = true
	zap.S().Infow("redis success",
		"component", "bus_eta",
		"action", "Bus_eta",
		"city", city,
		"event", "redis_success",
		"station_count", len(stations),
		"route_count", len(routes),
		"eat_count", len(eat),
		"posit_count", len(posit),
		"frozen_eta_count", countFrozenEstimates(eat),
		"fill_without_departure_count", fillsWithoutDeparture,
	)
	var ackErr error
	if etaModified && etaFetch != nil {
		ackErr = errors.Join(ackErr, pipeline.AcknowledgeTDXFetch(etaFetch))
	}
	if positionFetch.Modified {
		ackErr = errors.Join(ackErr, pipeline.AcknowledgeTDXFetch(positionFetch))
	}
	if ackErr != nil {
		return ackErr
	}
	if j.notifier != nil {
		if err := j.notifier.Arrivals(ctx, arrivalEvents); err != nil {
			return _oops.With("city", city).Wrapf(err, "dispatch bus arrival reminders")
		}
	}
	if observed {
		j.store.saveHistory(ctx, historyRows)
		j.store.recordPredictions(ctx, predictionRows)
	}
	return nil
}

func shouldDispatchBusArrival(found bool, status uint8, etaSeconds int32) bool {
	return found && status == 0 && etaSeconds > 0
}
