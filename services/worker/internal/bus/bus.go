package bus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// _busSubroutesUpsertSQL upserts one subroute per (sub_route_uid, direction) into
// bus_subroutes from the temp_bus staging table, building the stops array from
// the staged rawstop jsonb. DISTINCT ON dedupes staged duplicates.
const _busSubroutesUpsertSQL = `
			INSERT INTO bus_subroutes(
				sub_route_uid,
				route_uid,
				direction,
				route_name,
				sub_route_name,
				city,
				depart,
				destin,
				geometry,
				stops,
				schedule,
				operators
			)
			SELECT DISTINCT ON (uid, d) uid, rid, d, name1, name2,city,depart,destin,geom,
				   ARRAY(
					   SELECT ROW(
								  s ->> 'StationID',
								  s ->> 'StopName',
								  (s ->> 'StopSequence')::int,
								  (s ->> 'PositionLon')::float,
								  (s ->> 'PositionLat')::float
							  )::stop
					   FROM jsonb_array_elements(rawstop) AS s
				   ),schedule,operators
			FROM temp_bus
			ORDER BY uid, d
			ON CONFLICT (sub_route_uid, direction)
			DO UPDATE SET
				route_uid = EXCLUDED.route_uid,
				route_name = EXCLUDED.route_name,
				sub_route_name = EXCLUDED.sub_route_name,
				city = EXCLUDED.city,
				geometry = EXCLUDED.geometry,
				stops = EXCLUDED.stops,
				depart = EXCLUDED.depart,
				destin = EXCLUDED.destin,
				schedule = EXCLUDED.schedule,
				operators = EXCLUDED.operators,
				updated_at = NOW();
			`

const _busScheduleInsertSQL = `INSERT INTO bus_schedule (sub_route_uid, direction, type, tripid, islowfloor, stopsequence, "stop_uid/MinHeadwayMins", "stop_name/MaxHeadwayMins", "arrival_time/StartTime", "departure_time/EndTime", service_day, updated_at)
				SELECT uid, dir, type, id, floor, seq, stopuid, stopname, arrival::time, departure::time, sdays, NOW()
				FROM temp_bus_schedule`

var _operatorPhoneRun = regexp.MustCompile(`\d[\d\-() ]*\d|\d`)

func sanitizeOperatorPhone(s string) string {
	if !strings.ContainsRune(s, '�') {
		return s
	}
	return strings.Join(_operatorPhoneRun.FindAllString(s, -1), " / ")
}

func DailyTimetableLoadSkip(city string) bool {
	return dataset.BusDailyTimetableSkip(city) && city != dataset.DataTaipeiCity
}

// busDailyOriginFilter indexes each subroute direction's origin stop from the
// city's raw StopOfRoute landing so daily-timetable trips can be checked
// against the direction they claim.
type busDailyOriginFilter struct {
	originUID  map[string]map[string]struct{} // uid\x00dir -> origin StopUIDs across operator variants
	originName map[string]map[string]struct{} // uid\x00dir -> origin stop names
	stopName   map[string]string              // StopUID -> name, over every route's stop list
}

func busDailyOriginKey(uid string, dir uint8) string {
	return fmt.Sprintf("%s\x00%d", uid, dir)
}

// newBusDailyOriginFilter reads the city's raw StopOfRoute landing. A read or
// decode failure returns nil (filtering disabled): an unfiltered timetable is
// the pre-filter status quo, not worth failing the city's load over.
func newBusDailyOriginFilter(ctx context.Context, src pipeline.LoadSource, city string) *busDailyOriginFilter {
	if src == nil {
		return nil
	}
	body, _, err := src.DatasetJSON(ctx, "bus_stopofroute", "city", city)
	if err != nil {
		zap.S().Warnw("origin filter unavailable",
			"component", "load",
			"action", "bus_dailytimetable",
			"event", "origin_filter_unavailable",
			"city", city,
			"err", err,
		)
		return nil
	}
	var variants []busmodel.RawStopOfRoute
	if err := json.Unmarshal(body, &variants); err != nil {
		zap.S().Warnw("origin filter unavailable",
			"component", "load",
			"action", "bus_dailytimetable",
			"event", "origin_filter_unavailable",
			"city", city,
			"err", err,
		)
		return nil
	}
	f := &busDailyOriginFilter{
		originUID:  make(map[string]map[string]struct{}, len(variants)),
		originName: make(map[string]map[string]struct{}, len(variants)),
		stopName:   make(map[string]string, len(variants)*32),
	}
	for _, v := range variants {
		if len(v.Stops) == 0 {
			continue
		}
		uid, dir := shared.CanonicalSubroute(city, v.SubRouteUID, v.Direction)
		first := v.Stops[0]
		for _, s := range v.Stops {
			if s.StopSequence < first.StopSequence {
				first = s
			}
			f.stopName[s.StopUID] = s.StopName.Zhtw
		}
		key := busDailyOriginKey(uid, dir)
		if f.originUID[key] == nil {
			f.originUID[key] = make(map[string]struct{}, 1)
			f.originName[key] = make(map[string]struct{}, 1)
		}
		f.originUID[key][first.StopUID] = struct{}{}
		f.originName[key][first.StopName.Zhtw] = struct{}{}
	}
	return f
}

func (f *busDailyOriginFilter) keep(uid string, dir uint8, firstStopUID string) bool {
	if f == nil {
		return true
	}
	thisKey := busDailyOriginKey(uid, dir)
	if _, ok := f.originUID[thisKey][firstStopUID]; ok {
		return true
	}
	thisNames := f.originName[thisKey]
	if len(thisNames) == 0 {
		return true
	}
	otherNames := f.originName[busDailyOriginKey(uid, 1-dir)]
	for n := range thisNames {
		if _, ok := otherNames[n]; ok {
			return true
		}
	}
	name, ok := f.stopName[firstStopUID]
	if !ok {
		return true
	}
	if _, ok := thisNames[name]; ok {
		return true
	}
	if _, ok := otherNames[name]; ok {
		return false
	}
	return true
}

func LoadDailyTimetable(ctx context.Context, dec *json.Decoder, src pipeline.LoadSource, _ *pgxpool.Pool, rc *redis.Client, city string) error {
	if strings.TrimSpace(city) == "" {
		return errors.New("bus daily timetable: city is required")
	}
	entries, err := pipeline.DecodeLoadArray[busmodel.RawDailyTimetable](dec, "bus daily timetable "+city, func(_ int, timetable busmodel.RawDailyTimetable) error {
		return validateBusDailyTimetable(timetable)
	})
	if err != nil {
		return err
	}
	q := pipeline.NewQuarantine("bus_dailytimetable", city)
	defer q.Report()
	for _, temp := range entries {
		q.Consider("trip", len(temp.Timetables))
		for _, t := range temp.Timetables {
			q.Consider("stoptime", len(t.StopTimes))
		}
	}
	filter := newBusDailyOriginFilter(ctx, src, city)
	// Misfiled trips bypass the quarantine on purpose: Taoyuan misfiles ~40%
	// of its trips (see keep), and quarantine's ratio gate would fail the
	// whole city over an expected, correctly-filtered data shape.
	misfiled := 0
	misfiledSample := ""
	mp := make(map[string]map[int32]*models.Bus_DirectionTimetable, 300)
	seenTrips := make(map[string]*models.Bus_DailyTimetable)
	for _, temp := range entries {
		uid, dir, err := canonicalBusDailyIdentity(city, temp.SubRouteUID, *temp.Direction)
		if err != nil {
			return err
		}
		if _, exists := mp[uid]; !exists {
			mp[uid] = make(map[int32]*models.Bus_DirectionTimetable, 4)
		}
		if _, exists := mp[uid][int32(dir)]; !exists {
			mp[uid][int32(dir)] = &models.Bus_DirectionTimetable{
				DailyTimetables: make([]*models.Bus_DailyTimetable, 0, 64),
			}
		}
		for _, t := range temp.Timetables {
			firstStop := t.StopTimes[0]
			for _, st := range t.StopTimes[1:] {
				if st.StopSequence < firstStop.StopSequence {
					firstStop = st
				}
			}
			if !filter.keep(uid, dir, firstStop.StopUID) {
				misfiled++
				if misfiledSample == "" {
					misfiledSample = fmt.Sprintf("TripID %q for %s/%d departs %s", t.TripID, uid, dir, firstStop.StopUID)
				}
				continue
			}
			stop := make([]*models.Bus_StopTime, 0, len(t.StopTimes))
			seenStops := make(map[int64]*models.Bus_StopTime, len(t.StopTimes))
			for _, st := range t.StopTimes {
				candidate := &models.Bus_StopTime{
					StopSequence:  int32(st.StopSequence),
					ArrivalTime:   st.ArrivalTime,
					DepartureTime: st.DepartureTime,
					StopUID:       st.StopUID,
				}
				if prior, exists := seenStops[st.StopSequence]; exists {
					// First variant wins: TDX repeats a stop sequence with a
					// different time and does not say which is right, and one
					// such trip is not worth the city's whole timetable.
					if !proto.Equal(prior, candidate) {
						q.Drop("stoptime", "stoptime_divergent", fmt.Sprintf("TripID %q StopSequence %d", t.TripID, st.StopSequence))
					}
					continue
				}
				seenStops[st.StopSequence] = candidate
				stop = append(stop, candidate)
			}
			timetable := &models.Bus_DailyTimetable{
				TripID:     t.TripID,
				IsLowFloor: t.IsLowFloor,
				StopTimes:  stop,
			}
			key := fmt.Sprintf("%s\x00%d\x00%s", uid, dir, t.TripID)
			if prior, exists := seenTrips[key]; exists {
				// First variant wins, as for the stop times above.
				if !proto.Equal(prior, timetable) {
					q.Drop("trip", "trip_divergent", fmt.Sprintf("TripID %q for %s/%d", t.TripID, uid, dir))
				}
				continue
			}
			seenTrips[key] = timetable
			mp[uid][int32(dir)].DailyTimetables = append(mp[uid][int32(dir)].DailyTimetables, timetable)
		}
	}
	if misfiled > 0 {
		zap.S().Infow("misfiled direction trips",
			"component", "load",
			"action", "bus_dailytimetable",
			"event", "misfiled_direction_trips",
			"city", city,
			"dropped", misfiled,
			"first", pipeline.LogSafeDetail(misfiledSample),
		)
	}
	// Past the ratio the city's timetable fails instead of publishing a gutted
	// one; the previous load's Redis payload stays in place.
	if err := q.Exceeded(); err != nil {
		return err
	}
	type redisWrite struct {
		key   string
		value []byte
	}
	uids := make([]string, 0, len(mp))
	for uid := range mp {
		uids = append(uids, uid)
	}
	sort.Strings(uids)
	writes := make([]redisWrite, 0, len(uids))
	for _, subRouteUID := range uids {
		pbRoute := &models.Bus_DailyTimetables{
			SubRouteUID: subRouteUID,
			Direction:   mp[subRouteUID],
		}
		pb, err := (proto.MarshalOptions{Deterministic: true}).Marshal(pbRoute)
		if err != nil {
			return _oops.With("city", city).With("sub_route_uid", subRouteUID).Wrapf(err, "bus daily timetable marshal")
		}
		writes = append(writes, redisWrite{key: shared.BusDailyTimetableKey(subRouteUID), value: pb})
	}
	if len(writes) == 0 {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return _oops.With("city", city).Wrapf(err, "bus daily timetable context before Redis transaction")
	}
	if rc == nil {
		return _oops.With("city", city).Errorf("bus daily timetable Redis transaction: nil client")
	}
	pipe := rc.TxPipeline()
	defer pipe.Discard()
	for _, write := range writes {
		pipe.Set(ctx, write.key, write.value, 26*time.Hour)
	}
	if err := ctx.Err(); err != nil {
		pipe.Discard()
		return _oops.With("city", city).Wrapf(err, "bus daily timetable context before Redis transaction")
	}
	_, execErr := pipe.Exec(ctx)
	if ctxErr := ctx.Err(); ctxErr != nil {
		return _oops.With("city", city).Wrapf(errors.Join(ctxErr, execErr), "bus daily timetable context during Redis transaction")
	}
	if execErr != nil {
		return _oops.With("city", city).Wrapf(execErr, "bus daily timetable Redis transaction")
	}
	zap.S().Infow("complete", "component", "bus", "action", "bus_dailyroute", "event", "complete", "city", city)
	return nil
}

func validateBusDailyTimetable(timetable busmodel.RawDailyTimetable) error {
	if strings.TrimSpace(timetable.SubRouteUID) == "" {
		return errors.New("missing SubRouteUID")
	}
	if timetable.Direction == nil {
		return errors.New("missing Direction")
	}
	if *timetable.Direction > 1 {
		return _oops.With("direction", *timetable.Direction).Errorf("invalid Direction, want 0 or 1")
	}
	if len(timetable.Timetables) == 0 {
		return errors.New("missing Timetables")
	}
	for timetableIndex, trip := range timetable.Timetables {
		if strings.TrimSpace(trip.TripID) == "" {
			return _oops.With("timetable_index", timetableIndex).Errorf("timetables element missing TripID")
		}
		if len(trip.StopTimes) == 0 {
			return _oops.With("timetable_index", timetableIndex).Errorf("timetables element missing StopTimes")
		}
		for stopIndex, stop := range trip.StopTimes {
			prefix := fmt.Sprintf("Timetables element %d StopTimes element %d", timetableIndex, stopIndex)
			if stop.StopSequence <= 0 || stop.StopSequence > 1<<31-1 {
				return _oops.With("prefix", prefix).With("max", int64(1<<31-1)).Errorf("StopSequence out of range")
			}
			if strings.TrimSpace(stop.StopUID) == "" {
				return _oops.With("prefix", prefix).Errorf("StopUID is required")
			}
			if !pipeline.ValidClock(stop.ArrivalTime) {
				return _oops.With("prefix", prefix).With("arrival_time", stop.ArrivalTime).Errorf("ArrivalTime is invalid")
			}
			if !pipeline.ValidClock(stop.DepartureTime) {
				return _oops.With("prefix", prefix).With("departure_time", stop.DepartureTime).Errorf("DepartureTime is invalid")
			}
		}
	}
	return nil
}

func canonicalBusDailyIdentity(city, subRouteUID string, direction uint8) (string, uint8, error) {
	prefix, ok := busmodel.CityPrefix[city]
	if !ok || prefix == "" {
		return "", 0, _oops.With("city", city).Errorf("bus daily timetable: authority is unknown")
	}
	uid, dir := shared.CanonicalSubroute(city, subRouteUID, direction)
	if strings.TrimSpace(uid) == "" {
		return "", 0, _oops.With("city", city).With("sub_route_uid", subRouteUID).Errorf("bus daily timetable: canonical SubRouteUID is empty")
	}
	if dir > 1 {
		return "", 0, _oops.With("city", city).With("dir", dir).Errorf("bus daily timetable: canonical Direction must be 0 or 1")
	}
	if !uidBelongsToPrefix(uid, prefix) {
		return "", 0, _oops.With("city", city).With("uid", uid).With("prefix", prefix).Errorf("bus daily timetable: canonical SubRouteUID does not belong to authority")
	}
	return uid, dir, nil
}

// jsonOrNil returns nil for empty or literal-null JSON so the value is stored as
// SQL NULL rather than the string "null".
func jsonOrNil(r json.RawMessage) []byte {
	if len(r) == 0 || string(r) == "null" {
		return nil
	}
	return r
}

// cloneBusFare deep-copies a fare so a route-wide fare shared across subroutes
// can be attached to each without aliasing the same proto message. Returns nil
// for a nil input.
func cloneBusFare(f *models.Bus_Fare) *models.Bus_Fare {
	if f == nil {
		return nil
	}
	return proto.Clone(f).(*models.Bus_Fare)
}

func mergeBusFares(candidates []*models.Bus_Fare) *models.Bus_Fare {
	if len(candidates) == 1 {
		return cloneBusFare(candidates[0])
	}
	sections := make([][]byte, 0, len(candidates))
	stages := make([][]byte, 0, len(candidates))
	ods := make([][]byte, 0, len(candidates))
	for _, c := range candidates {
		sections = append(sections, c.SectionFaresJson)
		stages = append(stages, c.StageFaresJson)
		ods = append(ods, c.OdFaresJson)
	}
	return &models.Bus_Fare{
		FarePricingType:  candidates[0].FarePricingType,
		IsFreeBus:        candidates[0].IsFreeBus,
		SectionFaresJson: mergeFareJSONArrays(sections...),
		StageFaresJson:   mergeFareJSONArrays(stages...),
		OdFaresJson:      mergeFareJSONArrays(ods...),
	}
}

func mergeFareJSONArrays(payloads ...[]byte) []byte {
	seen := make(map[string]struct{})
	var merged []json.RawMessage
	for _, payload := range payloads {
		if len(payload) == 0 {
			continue
		}
		var entries []json.RawMessage
		if err := json.Unmarshal(payload, &entries); err != nil {
			continue
		}
		for _, entry := range entries {
			var canon map[string]any
			if err := json.Unmarshal(entry, &canon); err != nil {
				continue
			}
			key, err := json.Marshal(canon)
			if err != nil {
				continue
			}
			if _, dup := seen[string(key)]; dup {
				continue
			}
			seen[string(key)] = struct{}{}
			merged = append(merged, entry)
		}
	}
	if len(merged) == 0 {
		return nil
	}
	out, err := json.Marshal(merged)
	if err != nil {
		return nil
	}
	return out
}
