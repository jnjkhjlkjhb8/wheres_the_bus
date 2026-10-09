package bus

import (
	"slices"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

func parseSrcUpdateTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, true
	}
	for _, layout := range []string{"2006-01-02T15:04:05", "2006-01-02 15:04:05"} {
		if t, err := time.ParseInLocation(layout, s, pipeline.Taipei); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

func etaSourceTime(eta busmodel.RawEstimated) (time.Time, bool) {
	if t, ok := parseSrcUpdateTime(eta.SrcUpdateTime); ok {
		return t, true
	}
	return parseSrcUpdateTime(eta.SrcTransTime)
}

func adjustedEstimate(eta busmodel.RawEstimated, now time.Time) int32 {
	est := eta.EstimatedTime
	if srcT, ok := etaSourceTime(eta); ok {
		est -= int32(now.Sub(srcT).Seconds())
	}
	return max(est, 0)
}

// _busEtaNoReading is the StopStatus published for a stop with no usable TDX
// entry at all. Outside TDX's own 0-4 range, so the app falls through to its
// unknown branch and renders '–' rather than a service state it was never told.
const _busEtaNoReading uint8 = 67

// How long past its own predicted arrival instant a StopStatus 0 entry still
// counts as 進站中. One ETA cron period plus a minute of slack for TDX's own
// publish lag.
const _busEtaArrivingGrace = 90 * time.Second

func arrivingExpired(eta busmodel.RawEstimated, now time.Time) bool {
	srcT, ok := etaSourceTime(eta)
	if !ok {
		return false
	}
	arrival := srcT.Add(time.Duration(eta.EstimatedTime) * time.Second)
	return now.Sub(arrival) > _busEtaArrivingGrace
}

const _busEtaFrozenGap = 90 * time.Second

func countFrozenEstimates(eat []busmodel.RawEstimated) int {
	frozen := 0
	for _, e := range eat {
		srcT, srcOK := etaSourceTime(e)
		dataT, dataOK := parseSrcUpdateTime(e.DataTime)
		if !srcOK || !dataOK {
			continue
		}
		if srcT.Sub(dataT) > _busEtaFrozenGap {
			frozen++
		}
	}
	return frozen
}

// _busEtaDirectionUnknown is TDX's "direction not applicable" marker on an
// EstimatedTimeOfArrival entry. Tainan sends it on every schedule-only (StopStatus
// 1) entry, its SubRouteUID already naming the travel direction.
const _busEtaDirectionUnknown uint8 = 255

func buildBusEtaMap(city string, eat []busmodel.RawEstimated, mp []busmodel.StationMap) map[etaKey]busmodel.RawEstimated {
	subsByRoute := make(map[string][]string)
	dirsBySub := make(map[string][]uint8)
	seenSub := make(map[string]bool)
	for _, b := range mp {
		if !slices.Contains(dirsBySub[b.SubRouteUID], b.Direction) {
			dirsBySub[b.SubRouteUID] = append(dirsBySub[b.SubRouteUID], b.Direction)
		}
		if b.RouteUID == "" || seenSub[b.SubRouteUID] {
			continue
		}
		seenSub[b.SubRouteUID] = true
		subsByRoute[b.RouteUID] = append(subsByRoute[b.RouteUID], b.SubRouteUID)
	}
	etamap := make(map[etaKey]busmodel.RawEstimated)
	put := func(k etaKey, e busmodel.RawEstimated) {
		if prev, seen := etamap[k]; seen {
			etamap[k] = pickBusEstimate(prev, e)
		} else {
			etamap[k] = e
		}
	}
	for _, e := range eat {
		uid, dir := shared.CanonicalSubroute(city, e.SubRouteUID, e.Direction)
		subs := []string{uid}
		if e.SubRouteUID == "" {
			subs = subsByRoute[e.RouteUID]
		}
		for _, sub := range subs {
			dirs := []uint8{dir}
			if dir == _busEtaDirectionUnknown {
				dirs = dirsBySub[sub]
			}
			for _, d := range dirs {
				put(etaKey{sub, d, e.StopUID}, e)
			}
		}
	}
	return etamap
}

// parseGPSTimeUnix converts a TDX GPSTime string to epoch seconds. TDX usually
// sends RFC3339 with a +08:00 offset; some feeds drop the zone, which we read as
// Taipei local. Unparseable or empty values yield 0 (the client shows "無定位").
func parseGPSTimeUnix(s string) int64 {
	if s == "" {
		return 0
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.Unix()
	}
	for _, layout := range []string{"2006-01-02T15:04:05", "2006-01-02 15:04:05"} {
		if t, err := time.ParseInLocation(layout, s, pipeline.Taipei); err == nil {
			return t.Unix()
		}
	}
	return 0
}

func etaForStop(etamap map[etaKey]busmodel.RawEstimated, b busmodel.StationMap) (busmodel.RawEstimated, bool) {
	if eta, ok := etamap[etaKey{b.SubRouteUID, b.Direction, b.StopUID}]; ok {
		return eta, true
	}
	for _, alias := range b.AliasStopUIDs {
		if eta, ok := etamap[etaKey{b.SubRouteUID, b.Direction, alias}]; ok {
			return eta, true
		}
	}
	return busmodel.RawEstimated{}, false
}

// buildTotalStops counts the stops per canonical subroute from the static map,
// giving each stop its route length (a model feature, and stored on history
// rows).
func buildTotalStops(mp []busmodel.StationMap) map[string]int {
	totalStops := make(map[string]int)
	for _, b := range mp {
		totalStops[b.SubRouteUID]++
	}
	return totalStops
}

func collectFillKeys(mp []busmodel.StationMap, etamap map[etaKey]busmodel.RawEstimated) ([]predict.RouteDirKey, map[string]bool) {
	var fillKeys []predict.RouteDirKey
	fillUIDs := make(map[string]bool)
	for _, b := range mp {
		uid, dir := b.SubRouteUID, b.Direction
		etaEnt, ok := etaForStop(etamap, b)
		if !ok {
			continue
		}
		if etaEnt.StopStatus == 1 && etaEnt.NextBusTime == "" {
			fillKeys = append(fillKeys, predict.RouteDirKey{SubRouteUID: uid, Direction: int32(dir)})
			fillUIDs[uid] = true
		}
		// Delay propagation needs the baseline (schedule + running time) at upstream
		// stops where a live bus is en route, so include those routes' departures
		// and stop offsets in the batched lookups too.
		if etaEnt.StopStatus == 0 {
			fillKeys = append(fillKeys, predict.RouteDirKey{SubRouteUID: uid, Direction: int32(dir)})
			fillUIDs[uid] = true
		}
	}
	return fillKeys, fillUIDs
}

func buildUpstreamObs(
	mp []busmodel.StationMap,
	etamap map[etaKey]busmodel.RawEstimated,
	now time.Time,
	baselineFor func(b busmodel.StationMap, uid string, dir int32) time.Time,
) map[predict.RouteDirKey][]predict.UpstreamObs {
	upstreamByRoute := make(map[predict.RouteDirKey][]predict.UpstreamObs)
	for _, b := range mp {
		uid, cdir := b.SubRouteUID, b.Direction
		eta, ok := etaForStop(etamap, b)
		if !ok || eta.StopStatus != 0 {
			continue
		}
		dir := int32(cdir)
		est := adjustedEstimate(eta, now)
		baseline := baselineFor(b, uid, dir)
		if baseline.IsZero() {
			continue
		}
		observedArrival := now.Add(time.Duration(est) * time.Second)
		rk := predict.RouteDirKey{SubRouteUID: uid, Direction: dir}
		upstreamByRoute[rk] = append(upstreamByRoute[rk], predict.UpstreamObs{
			StopSequence: int(b.StopSequence),
			DelaySeconds: observedArrival.Sub(baseline).Seconds(),
			ObservedAt:   now,
		})
	}
	return upstreamByRoute
}

const (
	_busDutyStatusEnded    uint8 = 2
	_busStatusNotInService uint8 = 99
)

func busInService(bus *models.BusPosition) bool {
	return bus.DutyStatus != int32(_busDutyStatusEnded) &&
		bus.BusStatus != int32(_busStatusNotInService)
}

func nearestBus(lat, lon float64, buses []*models.BusPosition) (plate *string, speed *int16, dist *int) {
	if lat == 0 {
		return nil, nil, nil
	}
	var nearest *models.BusPosition
	var nearestDist float64
	for _, bus := range buses {
		if !busInService(bus) {
			continue
		}
		d := history.Haversine(lat, lon,
			float64(bus.PositionLat), float64(bus.PositionLon))
		if nearest == nil || d < nearestDist {
			nearestDist = d
			nearest = bus
		}
	}
	if nearest == nil {
		return nil, nil, nil
	}
	pn := nearest.PlateNumb
	spd := int16(nearest.Speed)
	di := int(nearestDist)
	return &pn, &spd, &di
}

// busAtStopKey identifies the stop one vehicle is standing at, on the same
// canonical subroute/direction axis as the rest of the ETA job.
type busAtStopKey struct {
	subRouteUID string
	direction   uint8
	stopUID     string
}

type stopPresence struct {
	plate string
	speed *int16
}

func buildBusAtStopMap(city string, positions []busmodel.RawPosition) map[busAtStopKey]stopPresence {
	out := make(map[busAtStopKey]stopPresence, len(positions))
	for _, p := range positions {
		if p.StopUID == "" {
			continue
		}
		// Same rule as nearestBus: a vehicle that ended its duty or is running
		// out of service is not the bus this stop's estimate is about, even when
		// the feed places it at the kerb.
		if p.DutyStatus == _busDutyStatusEnded || p.BusStatus == _busStatusNotInService {
			continue
		}
		plate := normalizeArrivalPlate(p.PlateNumb)
		if plate == "" {
			continue
		}
		speed := int16(p.Speed)
		uid, direction := shared.CanonicalSubroute(city, p.SubRouteUID, p.Direction)
		out[busAtStopKey{uid, direction, p.StopUID}] = stopPresence{plate: plate, speed: &speed}
	}
	return out
}

func busAtStop(index map[busAtStopKey]stopPresence, key busAtStopKey) (*string, *int16, *int, bool) {
	p, ok := index[key]
	if !ok {
		return nil, nil, nil, false
	}
	dist := 0
	return &p.plate, p.speed, &dist, true
}

func crowdForPlate(buses []*models.BusPosition, plate *string) models.BusCrowdLevel {
	if plate == nil || *plate == "" {
		return models.BusCrowdLevel_BUS_CROWD_UNKNOWN
	}
	for _, bus := range buses {
		if normalizeArrivalPlate(bus.PlateNumb) == *plate {
			return bus.CrowdLevel
		}
	}
	return models.BusCrowdLevel_BUS_CROWD_UNKNOWN
}

func computeArrivalUnix(status uint8, est int32, nextBusTime string, now time.Time) int64 {
	if status == 0 && est > 0 {
		return now.Add(time.Duration(est) * time.Second).Unix()
	}
	if status == 1 && nextBusTime != "" {
		if t, err := time.Parse(time.RFC3339, nextBusTime); err == nil {
			return t.Unix()
		}
	}
	return 0
}
