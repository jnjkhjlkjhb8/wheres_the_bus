package bus

import (
	"context"
	"encoding/json"
	"slices"
	"strconv"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/holiday"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/weather"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

type busCitySnapshot struct {
	ctx                   context.Context
	city                  string
	job                   busLiveJob
	stations              map[string]*models.Bus_StationArrival
	routes                map[string]*models.Bus_RouteArrival
	etamap                map[etaKey]busmodel.RawEstimated
	busmap                map[string][]*models.BusPosition
	atStopMap             map[busAtStopKey]stopPresence
	totalStops            map[string]int
	wx                    *weather.Data
	now                   time.Time
	isHoliday             bool
	depMap                map[predict.RouteDirKey]time.Time
	offsetMap             map[predict.StopOffsetKey]int
	baselineFor           func(busmodel.StationMap, string, int32) time.Time
	upstreamByRoute       map[predict.RouteDirKey][]predict.UpstreamObs
	predictionRows        []history.PredictionRecord
	historyRows           [][]any
	arrivalEvents         []riderevent.ArrivalEvent
	fillsWithoutDeparture int
}

func (j busLiveJob) prepareCitySnapshot(ctx context.Context, city string, mp []busmodel.StationMap, f *busCityFeeds) *busCitySnapshot {
	stations := make(map[string]*models.Bus_StationArrival)
	routes := make(map[string]*models.Bus_RouteArrival)
	etamap := buildBusEtaMap(city, f.eat, mp)
	f.posit = j.overlayVehicles(ctx, city, f.posit)
	now := j.now().In(pipeline.Taipei)
	busmap := buildDirectionAwareBusPositionMap(city, f.posit, now)
	atStopMap := buildBusAtStopMap(city, f.posit)
	for key, presence := range j.nearStops(ctx, city, now) {
		atStopMap[key] = presence
	}
	totalStops := buildTotalStops(mp)
	wx := j.cityWeather(ctx, city)
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
	return &busCitySnapshot{ctx: ctx, city: city, job: j, stations: stations, routes: routes, etamap: etamap, busmap: busmap, atStopMap: atStopMap, totalStops: totalStops, wx: wx, now: now, isHoliday: isHoliday, depMap: depMap, offsetMap: offsetMap, baselineFor: baselineFor, upstreamByRoute: upstreamByRoute, predictionRows: predictionRows, historyRows: historyRows, arrivalEvents: arrivalEvents, fillsWithoutDeparture: fillsWithoutDeparture}
}

func (j busLiveJob) cityWeather(ctx context.Context, city string) *weather.Data {
	var wx *weather.Data
	if wjson, wErr := j.sink.GetString(ctx, shared.WeatherKey(city)); wErr == nil {
		var w weather.Data
		if json.Unmarshal([]byte(wjson), &w) == nil {
			wx = &w
		}
	}
	return wx
}

func (r *busCitySnapshot) resolveStops(stops []busmodel.StationMap) {
	for _, stop := range stops {
		r.resolveStop(stop)
	}
}

func (r *busCitySnapshot) resolveStop(b busmodel.StationMap) {
	uid, dir := b.SubRouteUID, b.Direction
	positionKey := busPositionIdentity(uid, dir)
	eta, ok := etaForStop(r.etamap, b)
	status, est, stime := liveStopEstimate(eta, ok, r.now)
	var plateNumb *string
	if status == 0 {
		plateNumb = r.liveStopHistory(b, eta, est, stime, positionKey)
	}
	eta, fillSource := r.fillScheduleOnlyStop(b, eta, status)
	source := estimateSourceFor(status, fillSource)
	arrivalUnix := computeArrivalUnix(status, est, eta.NextBusTime, r.now)
	r.appendStationStop(b, eta, status, est, stime, positionKey, arrivalUnix, plateNumb, source)
	if shouldDispatchBusArrival(ok, status, est) {
		r.arrivalEvents = append(r.arrivalEvents, riderevent.ArrivalEvent{
			RouteType: "bus", RouteKey: uid, StopKey: b.StopUID,
			Direction: strconv.Itoa(int(dir)), ETASeconds: est,
			ArrivingPlate: normalizeArrivalPlate(eta.PlateNumb),
		})
	}
	r.appendRouteStop(b, eta, status, est, stime, positionKey, arrivalUnix, plateNumb, source)
}

// fillScheduleOnlyStop returns the history.Source* label of the prediction it
// wrote into eta.NextBusTime, or "" when the stop kept TDX's own value.
func (r *busCitySnapshot) fillScheduleOnlyStop(b busmodel.StationMap, eta busmodel.RawEstimated, status uint8) (busmodel.RawEstimated, string) {
	if status == 1 && eta.NextBusTime == "" {
		return r.fillStopTime(b, eta)
	}
	return eta, ""
}

// estimateSourceFor tells the client how far to trust a stop's time. Only a
// StopStatus 0 reading comes from a vehicle; a status 1 clock is TDX's
// timetable unless this job replaced it with a propagated or model prediction.
// Service-state statuses carry no time, so no source is claimed for them.
func estimateSourceFor(status uint8, fillSource string) models.BusEstimateSource {
	switch status {
	case 0:
		return models.BusEstimateSource_BUS_ESTIMATE_SOURCE_LIVE
	case 1:
		return clockEstimateSource(fillSource)
	default:
		return models.BusEstimateSource_BUS_ESTIMATE_SOURCE_UNSPECIFIED
	}
}

func clockEstimateSource(fillSource string) models.BusEstimateSource {
	if fillSource == history.SourcePropagation || fillSource == history.SourceModel {
		return models.BusEstimateSource_BUS_ESTIMATE_SOURCE_PREDICTED
	}
	return models.BusEstimateSource_BUS_ESTIMATE_SOURCE_SCHEDULED
}

func liveStopEstimate(eta busmodel.RawEstimated, ok bool, now time.Time) (uint8, int32, string) {
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
	return status, est, stime
}

func (r *busCitySnapshot) liveStopHistory(b busmodel.StationMap, eta busmodel.RawEstimated, est int32, stime, positionKey string) *string {
	plateNumb, busSpeed, busDist := r.resolvedStopBus(b, positionKey)
	if p := normalizeArrivalPlate(eta.PlateNumb); p != "" {
		plateNumb = &p
	}
	if history.RecordsHistory(est, r.job.snapshot) {
		r.recordStopHistory(b, eta, est, stime, plateNumb, busSpeed, busDist)
	}
	return plateNumb
}

func (r *busCitySnapshot) resolvedStopBus(b busmodel.StationMap, positionKey string) (*string, *int16, *int) {
	uid, dir := b.SubRouteUID, b.Direction
	plateNumb, busSpeed, busDist := nearestBus(b.Lat, b.Lon, r.busmap[positionKey])
	if plate, speed, dist, ok := busAtStop(r.atStopMap, busAtStopKey{uid, dir, b.StopUID}); ok {
		plateNumb, busDist = plate, dist
		if speed != nil {
			busSpeed = speed
		}
	}
	return plateNumb, busSpeed, busDist
}

func (r *busCitySnapshot) recordStopHistory(b busmodel.StationMap, eta busmodel.RawEstimated, est int32, stime string, plateNumb *string, busSpeed *int16, busDist *int) {
	uid, dir := b.SubRouteUID, b.Direction
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
	weatherTemp, weatherPrecip, weatherWind, weatherHumid := historyWeatherFields(r.wx)
	r.historyRows = append(r.historyRows, []any{
		uid, b.StopUID, int16(dir),
		int16(b.StopSequence), int16(r.totalStops[uid]), est, nextBusTimePtr, srcTime,
		r.city, int16(r.now.Hour()), int16(r.now.Weekday()), r.isHoliday,
		weatherTemp, weatherPrecip, weatherWind, weatherHumid,
		plateNumb, busSpeed, busDist, r.now,
	})
}

func historyWeatherFields(wx *weather.Data) (temp, precip, wind, humidity any) {
	if wx != nil {
		return wx.Temperature, wx.Precipitation, wx.WindSpeed, wx.Humidity
	}
	return nil, nil, nil, nil
}

func (r *busCitySnapshot) fillStopTime(b busmodel.StationMap, eta busmodel.RawEstimated) (busmodel.RawEstimated, string) {
	uid, dir := b.SubRouteUID, b.Direction
	rk := predict.RouteDirKey{SubRouteUID: uid, Direction: int32(dir)}
	if r.depMap[rk].IsZero() {
		r.fillsWithoutDeparture++
	}
	var predictedArrival time.Time
	var predSource string
	if propArrival, propOK := predict.PropagateDelay(
		r.baselineFor(b, uid, int32(dir)), int(b.StopSequence), r.upstreamByRoute[rk], r.now,
	); propOK {
		predictedArrival = propArrival
		predSource = history.SourcePropagation
		eta.NextBusTime = propArrival.Format(time.RFC3339)
	} else {
		eta.NextBusTime, predictedArrival, predSource = r.modelStopTime(b, rk)
	}
	r.recordStopPrediction(b, predSource, predictedArrival)
	return eta, predSource
}

func (r *busCitySnapshot) recordStopPrediction(b busmodel.StationMap, predSource string, predictedArrival time.Time) {
	uid, dir := b.SubRouteUID, b.Direction
	// Record the prediction (actual pending) for daily MAE measurement.
	if predSource != "" && !predictedArrival.IsZero() {
		r.predictionRows = append(r.predictionRows, history.PredictionRecord{SubRouteUID: uid,
			Direction:     int16(dir),
			StopUID:       b.StopUID,
			Source:        predSource,
			PredictedAt:   r.now,
			PredictedSecs: int(predictedArrival.Sub(r.now).Round(time.Second).Seconds()),
		})
	}
}

func (r *busCitySnapshot) modelStopTime(b busmodel.StationMap, rk predict.RouteDirKey) (nextBusTime string, predictedArrival time.Time, predSource string) {
	uid, dir := b.SubRouteUID, b.Direction
	offsetSec, hasOffset := r.offsetMap[predict.StopOffsetKey{SubRouteUID: uid, Direction: int32(dir), StopUID: b.StopUID}]
	nextBusTime = predict.NextBusTime(r.wx,
		predict.StopCtx{
			SubRouteUID:  uid,
			Direction:    int32(dir),
			StopUID:      b.StopUID,
			City:         r.city,
			StopSequence: int(b.StopSequence),
			TotalStops:   r.totalStops[uid],
		},
		predict.Inputs{
			Now:       r.now,
			NextDep:   r.depMap[rk],
			OffsetSec: offsetSec,
			HasOffset: hasOffset,
		},
	)
	predictedArrival, predSource = decodeModelStopTime(nextBusTime, hasOffset)
	return nextBusTime, predictedArrival, predSource
}

func decodeModelStopTime(nextBusTime string, hasOffset bool) (predictedArrival time.Time, predSource string) {
	if nextBusTime != "" {
		if t, err := time.Parse(time.RFC3339, nextBusTime); err == nil {
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
	return predictedArrival, predSource
}

func (r *busCitySnapshot) appendStationStop(b busmodel.StationMap, eta busmodel.RawEstimated, status uint8, est int32, stime, positionKey string, arrivalUnix int64, plateNumb *string, source models.BusEstimateSource) {
	uid, dir := b.SubRouteUID, b.Direction
	station := r.stationSnapshot(b)
	station.Routes = append(station.Routes, &models.Bus_StopEstimate{
		StopUid:        b.StationUID,
		SubRouteUid:    uid,
		RouteName:      b.SubRouteName,
		Destination:    b.Destination,
		Direction:      int32(dir),
		Estimate:       est,
		NextBusTime:    eta.NextBusTime,
		StopStatus:     int32(status),
		SrcUpdateTime:  stime,
		Buses:          r.busmap[positionKey],
		ArrivalUnix:    arrivalUnix,
		CrowdLevel:     crowdForPlate(r.busmap[positionKey], plateNumb),
		IsLastBus:      eta.IsLastBus == 1,
		EstimateSource: source,
	})
}

func (r *busCitySnapshot) stationSnapshot(b busmodel.StationMap) *models.Bus_StationArrival {
	groupUID, groupName := busStationGroup(b)
	if _, exists := r.stations[groupUID]; !exists {
		r.stations[groupUID] = &models.Bus_StationArrival{
			StationName: groupName,
		}
	}
	station := r.stations[groupUID]
	if !slices.Contains(station.StationUid, b.StationUID) {
		station.StationUid = append(station.StationUid, b.StationUID)
	}
	return station
}

func busStationGroup(b busmodel.StationMap) (string, string) {
	groupUID := b.GroupUID
	if groupUID == "" {
		groupUID = b.StationUID
	}
	groupName := b.GroupName
	if groupName == "" {
		groupName = b.StationName
	}
	return groupUID, groupName
}

func (r *busCitySnapshot) appendRouteStop(b busmodel.StationMap, eta busmodel.RawEstimated, status uint8, est int32, stime, positionKey string, arrivalUnix int64, plateNumb *string, source models.BusEstimateSource) {
	uid, dir := b.SubRouteUID, b.Direction
	if _, ok := r.routes[uid]; !ok {
		r.routes[uid] = &models.Bus_RouteArrival{
			SubRouteUid: uid,
		}
	}
	r.routes[uid].Stops = append(r.routes[uid].Stops, &models.Bus_RouteEstimate{
		StopUid:        b.StopUID,
		Direction:      int32(dir),
		Estimate:       est,
		StopStatus:     int32(status),
		NextBusTime:    eta.NextBusTime,
		SrcUpdateTime:  stime,
		Buses:          r.busmap[positionKey],
		StopSequence:   int32(b.StopSequence),
		ArrivalUnix:    arrivalUnix,
		PlateNumb:      normalizeArrivalPlate(eta.PlateNumb),
		CrowdLevel:     crowdForPlate(r.busmap[positionKey], plateNumb),
		IsLastBus:      eta.IsLastBus == 1,
		EstimateSource: source,
	})
}

func (r *busCitySnapshot) queueSnapshots(pipe pipeline.LivePipe) error {
	for groupUID, pb := range r.stations {
		data, err := proto.Marshal(pb)
		if err != nil {
			return err
		}
		key := shared.BusStationEtaKey(r.city, groupUID)
		pipe.Set(key, data, pipeline.BusLiveTTL)
		pipe.Publish(key, data)
	}
	return r.queueRouteSnapshots(pipe)
}

func (r *busCitySnapshot) queueRouteSnapshots(pipe pipeline.LivePipe) error {
	for uid, pb := range r.routes {
		data, err := proto.Marshal(pb)
		if err != nil {
			return err
		}
		key := shared.BusRouteEtaKey(uid)
		pipe.Set(key, data, pipeline.BusLiveTTL)
		pipe.Publish(key, data)
	}
	return nil
}

func (j busLiveJob) executeCitySnapshot(ctx context.Context, city string, f *busCityFeeds, r *busCitySnapshot, pipe pipeline.LivePipe) error {
	err := pipe.Exec(ctx)
	if err != nil {
		return _oops.With("city", city).With("stations", len(r.stations)).With("routes", len(r.routes)).With("eat", len(f.eat)).With("posit", len(f.posit)).Wrapf(err, "publish bus realtime snapshot for (stations= routes= eta= positions=)")
	}
	zap.S().Infow("redis success",
		"component", "bus_eta",
		"action", "Bus_eta",
		"city", city,
		"event", "redis_success",
		"station_count", len(r.stations),
		"route_count", len(r.routes),
		"eat_count", len(f.eat),
		"posit_count", len(f.posit),
		"frozen_eta_count", countFrozenEstimates(f.eat),
		"fill_without_departure_count", r.fillsWithoutDeparture,
	)
	return nil
}
