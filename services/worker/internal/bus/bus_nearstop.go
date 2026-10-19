package bus

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

var _busNearStopCities = map[string]struct{}{
	"InterCity":      {},
	"Keelung":        {},
	"Hsinchu":        {},
	"HsinchuCounty":  {},
	"MiaoliCounty":   {},
	"NantouCounty":   {},
	"ChanghuaCounty": {},
	"YunlinCounty":   {},
	"Chiayi":         {},
	"ChiayiCounty":   {},
	"PingtungCounty": {},
	"YilanCounty":    {},
	"HualienCounty":  {},
	"TaitungCounty":  {},
	"PenghuCounty":   {},
}

// rawBusNearStop decodes a TDX Bus/RealTimeNearStop element: one vehicle's
// arrival at, or departure from, one stop of one subroute.
type rawBusNearStop struct {
	PlateNumb    string `json:"PlateNumb"`
	SubRouteUID  string `json:"SubRouteUID"`
	Direction    uint8  `json:"Direction"`
	StopUID      string `json:"StopUID"`
	StopSequence uint8  `json:"StopSequence"`
	A2EventType  uint8  `json:"A2EventType"`
	DutyStatus   uint8  `json:"DutyStatus"`
	BusStatus    uint8  `json:"BusStatus"`
	GPSTime      string `json:"GPSTime"`
	// TripStartTime is the run's first-stop departure and TripStartTimeType says
	// how it was arrived at: 0 actual, 1 estimated from segment travel times,
	// 2 not derivable.
	TripStartTime     string `json:"TripStartTime"`
	TripStartTimeType uint8  `json:"TripStartTimeType"`
}

const (
	_busA2EventDepart uint8 = 0
	_busA2EventArrive uint8 = 1
)

const _busNearStopMaxAge = 90 * time.Second

func nearStopRecords(ctx context.Context, fetch pipeline.BoundFetch, city string) ([]rawBusNearStop, error) {
	url := busCityFeedURL("RealTimeNearStop", city)
	result, err := fetch(ctx, url, "bus_RealTimeNearStop"+city)
	if err != nil {
		return nil, _oops.With("city", city).Wrapf(err, "fetch bus near-stop events")
	}
	if !result.Modified {
		return nil, pipeline.InvalidateTDXFetch(result)
	}
	return decodeNearStopRecords(result, city)
}

func decodeNearStopRecords(result *shared.TDXFetch, city string) ([]rawBusNearStop, error) {
	rows := make([]rawBusNearStop, 0)
	if err := pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error {
		return pipeline.DecodeLiveItems(dec, func(r rawBusNearStop) error {
			rows = append(rows, r)
			return nil
		})
	}); err != nil {
		return nil, _oops.With("city", city).Wrapf(err, "decode bus near-stop events")
	}
	return rows, nil
}

func buildNearStopIndex(city string, rows []rawBusNearStop, now time.Time) map[busAtStopKey]stopPresence {
	index := make(map[busAtStopKey]stopPresence, len(rows))
	for _, r := range rows {
		plate := normalizeArrivalPlate(r.PlateNumb)
		if !usableNearStop(r, plate, now) {
			continue
		}
		uid, direction := shared.CanonicalSubroute(city, r.SubRouteUID, r.Direction)
		index[busAtStopKey{uid, direction, r.StopUID}] = stopPresence{plate: plate}
	}
	return index
}

func usableNearStop(r rawBusNearStop, plate string, now time.Time) bool {
	if !validNearStopIdentity(r, plate) || !nearStopInService(r) {
		return false
	}
	at := parseGPSTimeUnix(r.GPSTime)
	return freshNearStop(at, now)
}

func validNearStopIdentity(r rawBusNearStop, plate string) bool {
	return r.StopUID != "" && plate != ""
}
func nearStopInService(r rawBusNearStop) bool {
	return r.A2EventType == _busA2EventArrive && r.DutyStatus != _busDutyStatusEnded && r.BusStatus != _busStatusNotInService
}

func freshNearStop(at int64, now time.Time) bool {
	return at != 0 && now.Sub(time.Unix(at, 0)) <= _busNearStopMaxAge
}

func (j *busLiveJob) nearStops(ctx context.Context, city string, now time.Time) map[busAtStopKey]stopPresence {
	if _, ok := _busNearStopCities[city]; !ok {
		return nil
	}
	rows, err := nearStopRecords(ctx, j.fetch, city)
	if err != nil {
		zap.S().Warnw("fetch failed; falling back to nearest-GPS attribution",
			"component", "bus_nearstop",
			"action", "near_stop",
			"city", city,
			"err", err,
		)
		return nil
	}
	j.store.saveStopEvents(ctx, busStopEventRows(city, rows, now))
	return buildNearStopIndex(city, rows, now)
}

func busStopEventRows(city string, rows []rawBusNearStop, now time.Time) [][]any {
	out := make([][]any, 0, len(rows))
	for _, r := range rows {
		plate := normalizeArrivalPlate(r.PlateNumb)
		at := parseGPSTimeUnix(r.GPSTime)
		if !archivableNearStop(plate, r.StopUID, at) {
			continue
		}
		uid, direction := shared.CanonicalSubroute(city, r.SubRouteUID, r.Direction)
		tripStart := nearStopTripStart(r.TripStartTime)
		out = append(out, []any{
			plate, city, uid, int16(direction), r.StopUID, int16(r.StopSequence),
			int16(r.A2EventType), time.Unix(at, 0), tripStart, int16(r.TripStartTimeType), now,
		})
	}
	return out
}

func archivableNearStop(plate, stop string, at int64) bool {
	return plate != "" && stop != "" && at != 0
}
func nearStopTripStart(raw string) any {
	if t, ok := parseSrcUpdateTime(raw); ok {
		return t
	}
	return nil
}
