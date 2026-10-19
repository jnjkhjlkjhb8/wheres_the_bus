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
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
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
	return decodeBusDailyOriginFilter(body, city)
}

func decodeBusDailyOriginFilter(body []byte, city string) *busDailyOriginFilter {
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
	return buildBusDailyOriginFilter(variants, city)
}

func buildBusDailyOriginFilter(variants []busmodel.RawStopOfRoute, city string) *busDailyOriginFilter {
	f := &busDailyOriginFilter{
		originUID:  make(map[string]map[string]struct{}, len(variants)),
		originName: make(map[string]map[string]struct{}, len(variants)),
		stopName:   make(map[string]string, len(variants)*32),
	}
	for _, v := range variants {
		f.addOrigin(city, v)
	}

	return f
}

func (f *busDailyOriginFilter) addOrigin(city string, v busmodel.RawStopOfRoute) {
	if len(v.Stops) == 0 {
		return
	}
	uid, dir := shared.CanonicalSubroute(city, v.SubRouteUID, v.Direction)
	first := v.Stops[f.indexOriginStops(v)]
	key := busDailyOriginKey(uid, dir)
	if f.originUID[key] == nil {
		f.originUID[key] = make(map[string]struct{}, 1)
		f.originName[key] = make(map[string]struct{}, 1)
	}
	f.originUID[key][first.StopUID] = struct{}{}
	f.originName[key][first.StopName.Zhtw] = struct{}{}
}

func (f *busDailyOriginFilter) indexOriginStops(v busmodel.RawStopOfRoute) int {
	first := 0
	for index, stop := range v.Stops {
		if stop.StopSequence < v.Stops[first].StopSequence {
			first = index
		}
		f.stopName[stop.StopUID] = stop.StopName.Zhtw
	}
	return first
}

func (f *busDailyOriginFilter) keep(uid string, dir uint8, firstStopUID string) bool {
	if f == nil {
		return true
	}
	return f.keepKnownOrigin(uid, dir, firstStopUID)
}

func (f *busDailyOriginFilter) keepKnownOrigin(uid string, dir uint8, firstStopUID string) bool {
	thisKey := busDailyOriginKey(uid, dir)
	if _, ok := f.originUID[thisKey][firstStopUID]; ok {
		return true
	}
	thisNames := f.originName[thisKey]
	if len(thisNames) == 0 {
		return true
	}
	return f.keepDirectionOrigin(firstStopUID, thisNames, f.originName[busDailyOriginKey(uid, 1-dir)])
}

func (f *busDailyOriginFilter) keepDirectionOrigin(firstStopUID string, thisNames, otherNames map[string]struct{}) bool {
	if commonBusOrigin(thisNames, otherNames) {
		return true
	}
	return f.keepNamedOrigin(firstStopUID, thisNames, otherNames)
}

func (f *busDailyOriginFilter) keepNamedOrigin(firstStopUID string, thisNames, otherNames map[string]struct{}) bool {
	name, ok := f.stopName[firstStopUID]
	if !ok {
		return true
	}
	if _, ok := thisNames[name]; ok {
		return true
	}
	_, matchesOther := otherNames[name]
	return !matchesOther
}

func commonBusOrigin(thisNames, otherNames map[string]struct{}) bool {
	for n := range thisNames {
		if _, ok := otherNames[n]; ok {
			return true
		}
	}
	return false
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
	countDailyTimetableEntries(q, entries)
	return loadDecodedDailyTimetable(ctx, src, rc, city, entries, q)
}

func countDailyTimetableEntries(q *pipeline.Quarantine, entries []busmodel.RawDailyTimetable) {
	for _, temp := range entries {
		q.Consider("trip", len(temp.Timetables))
		for _, t := range temp.Timetables {
			q.Consider("stoptime", len(t.StopTimes))
		}
	}
}

func loadDecodedDailyTimetable(ctx context.Context, src pipeline.LoadSource, rc *redis.Client, city string, entries []busmodel.RawDailyTimetable, q *pipeline.Quarantine) error {
	filter := newBusDailyOriginFilter(ctx, src, city)
	mp, misfiled, misfiledSample, err := buildBusDailyTimetables(entries, city, filter, q)
	if err != nil {
		return err
	}

	reportMisfiledBusTrips(city, misfiled, misfiledSample)
	// Past the ratio the city's timetable fails instead of publishing a gutted
	// one; the previous load's Redis payload stays in place.
	if err := q.Exceeded(); err != nil {
		return err
	}
	return writeBusDailyTimetables(ctx, rc, city, mp)
}

func reportMisfiledBusTrips(city string, misfiled int, misfiledSample string) {
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
}

type busDailyBuilder struct {
	city           string
	filter         *busDailyOriginFilter
	q              *pipeline.Quarantine
	mp             map[string]map[int32]*models.Bus_DirectionTimetable
	seenTrips      map[string]*models.Bus_DailyTimetable
	misfiled       int
	misfiledSample string
}

func buildBusDailyTimetables(entries []busmodel.RawDailyTimetable, city string, filter *busDailyOriginFilter, q *pipeline.Quarantine) (map[string]map[int32]*models.Bus_DirectionTimetable, int, string, error) {
	// Misfiled trips bypass the quarantine on purpose: Taoyuan misfiles ~40%
	// of its trips (see keep), and quarantine's ratio gate would fail the
	// whole city over an expected, correctly-filtered data shape.
	b := busDailyBuilder{city: city, filter: filter, q: q, mp: make(map[string]map[int32]*models.Bus_DirectionTimetable, 300), seenTrips: make(map[string]*models.Bus_DailyTimetable)}
	for _, entry := range entries {
		if err := b.addEntry(entry); err != nil {
			return nil, 0, "", err
		}
	}
	return b.mp, b.misfiled, b.misfiledSample, nil
}
func (b *busDailyBuilder) addEntry(temp busmodel.RawDailyTimetable) error {
	city := b.city
	uid, dir, err := canonicalBusDailyIdentity(city, temp.SubRouteUID, *temp.Direction)
	if err != nil {
		return err
	}
	b.ensureDirection(uid, dir)
	for ti := range temp.Timetables {
		b.addTrip(uid, dir, temp, ti)
	}
	return nil
}
func (b *busDailyBuilder) ensureDirection(uid string, dir uint8) {
	if _, exists := b.mp[uid]; !exists {
		b.mp[uid] = make(map[int32]*models.Bus_DirectionTimetable, 4)
	}
	if _, exists := b.mp[uid][int32(dir)]; !exists {
		b.mp[uid][int32(dir)] = &models.Bus_DirectionTimetable{
			DailyTimetables: make([]*models.Bus_DailyTimetable, 0, 64),
		}
	}
}

func (b *busDailyBuilder) addTrip(uid string, dir uint8, temp busmodel.RawDailyTimetable, ti int) {
	t := temp.Timetables[ti]
	if !b.acceptTripOrigin(uid, dir, temp, ti) {
		return
	}
	stop := b.tripStops(temp, ti)
	timetable := &models.Bus_DailyTimetable{
		TripID:     t.TripID,
		IsLowFloor: t.IsLowFloor,
		StopTimes:  stop,
	}
	b.appendTimetable(uid, dir, timetable)
}

func firstBusDailyStopIndex(temp busmodel.RawDailyTimetable, ti int) int {
	stops := temp.Timetables[ti].StopTimes
	first := 0
	for index := range stops {
		if stops[index].StopSequence < stops[first].StopSequence {
			first = index
		}
	}
	return first
}

func (b *busDailyBuilder) acceptTripOrigin(uid string, dir uint8, temp busmodel.RawDailyTimetable, ti int) bool {
	trip := temp.Timetables[ti]
	first := trip.StopTimes[firstBusDailyStopIndex(temp, ti)]
	if b.filter.keep(uid, dir, first.StopUID) {
		return true
	}
	b.misfiled++
	if b.misfiledSample == "" {
		b.misfiledSample = fmt.Sprintf("TripID %q for %s/%d departs %s", trip.TripID, uid, dir, first.StopUID)
	}
	return false
}

func (b *busDailyBuilder) appendTimetable(uid string, dir uint8, timetable *models.Bus_DailyTimetable) {
	key := fmt.Sprintf("%s\x00%d\x00%s", uid, dir, timetable.TripID)
	if prior, exists := b.seenTrips[key]; exists {
		// First variant wins, as for the stop times above.
		if !proto.Equal(prior, timetable) {
			b.q.Drop("trip", "trip_divergent", fmt.Sprintf("TripID %q for %s/%d", timetable.TripID, uid, dir))
		}
		return
	}
	b.seenTrips[key] = timetable
	b.mp[uid][int32(dir)].DailyTimetables = append(b.mp[uid][int32(dir)].DailyTimetables, timetable)
}
func (b *busDailyBuilder) tripStops(temp busmodel.RawDailyTimetable, ti int) []*models.Bus_StopTime {
	t, q := temp.Timetables[ti], b.q
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
	return stop
}

func writeBusDailyTimetables(ctx context.Context, rc *redis.Client, city string, mp map[string]map[int32]*models.Bus_DirectionTimetable) error {
	writes, err := marshalBusDailyTimetables(city, mp)
	if err != nil {
		return err
	}
	return writeMarshaledBusDailyTimetables(ctx, rc, city, writes)
}

func writeMarshaledBusDailyTimetables(ctx context.Context, rc *redis.Client, city string, writes []redisWrite) error {
	if len(writes) == 0 {
		return nil
	}
	if err := validateBusDailyClient(ctx, rc, city); err != nil {
		return err
	}
	return sendBusDailyTimetables(ctx, rc, city, writes)
}

func validateBusDailyClient(ctx context.Context, rc *redis.Client, city string) error {
	if err := ctx.Err(); err != nil {
		return _oops.With("city", city).Wrapf(err, "bus daily timetable context before Redis transaction")
	}
	if rc == nil {
		return _oops.With("city", city).Errorf("bus daily timetable Redis transaction: nil client")
	}
	return nil
}

func sendBusDailyTimetables(ctx context.Context, rc *redis.Client, city string, writes []redisWrite) error {
	pipe := rc.TxPipeline()
	defer pipe.Discard()
	queueBusDailyWrites(ctx, pipe, writes)
	if err := executeBusDailyWrites(ctx, pipe, city); err != nil {
		return err
	}
	zap.S().Infow("complete", "component", "bus", "action", "bus_dailyroute", "event", "complete", "city", city)
	return nil
}

func queueBusDailyWrites(ctx context.Context, pipe redis.Pipeliner, writes []redisWrite) {
	for _, write := range writes {
		pipe.Set(ctx, write.key, write.value, 26*time.Hour)
	}
}

type redisWrite struct {
	key   string
	value []byte
}

func marshalBusDailyTimetables(city string, mp map[string]map[int32]*models.Bus_DirectionTimetable) ([]redisWrite, error) {
	uids := sortedDailyTimetableUIDs(mp)
	writes := make([]redisWrite, 0, len(uids))
	for _, subRouteUID := range uids {
		pbRoute := &models.Bus_DailyTimetables{
			SubRouteUID: subRouteUID,
			Direction:   mp[subRouteUID],
		}
		pb, err := (proto.MarshalOptions{Deterministic: true}).Marshal(pbRoute)
		if err != nil {
			return nil, _oops.With("city", city).With("sub_route_uid", subRouteUID).Wrapf(err, "bus daily timetable marshal")
		}
		writes = append(writes, redisWrite{key: shared.BusDailyTimetableKey(subRouteUID), value: pb})
	}
	return writes, nil
}

func sortedDailyTimetableUIDs(routes map[string]map[int32]*models.Bus_DirectionTimetable) []string {
	uids := make([]string, 0, len(routes))
	for uid := range routes {
		uids = append(uids, uid)
	}
	sort.Strings(uids)
	return uids
}

func validateBusDailyTimetable(timetable busmodel.RawDailyTimetable) error {
	if err := validateDailyTimetableIdentity(timetable); err != nil {
		return err
	}
	if len(timetable.Timetables) == 0 {
		return errors.New("missing Timetables")
	}
	return validateDailyTimetableTrips(timetable)
}

func validateDailyTimetableIdentity(timetable busmodel.RawDailyTimetable) error {
	if strings.TrimSpace(timetable.SubRouteUID) == "" {
		return errors.New("missing SubRouteUID")
	}
	return validateDailyTimetableDirection(timetable.Direction)
}

func validateDailyTimetableDirection(direction *uint8) error {
	if direction == nil {
		return errors.New("missing Direction")
	}
	if *direction > 1 {
		return _oops.With("direction", *direction).Errorf("invalid Direction, want 0 or 1")
	}
	return nil
}

func validateDailyTimetableTrips(timetable busmodel.RawDailyTimetable) error {
	for i := range timetable.Timetables {
		if err := validateBusDailyTrip(timetable, i); err != nil {
			return err
		}
	}
	return nil
}

func validateBusDailyTrip(timetable busmodel.RawDailyTimetable, timetableIndex int) error {
	trip := timetable.Timetables[timetableIndex]
	if strings.TrimSpace(trip.TripID) == "" {
		return _oops.With("timetable_index", timetableIndex).Errorf("timetables element missing TripID")
	}
	if len(trip.StopTimes) == 0 {
		return _oops.With("timetable_index", timetableIndex).Errorf("timetables element missing StopTimes")
	}
	return validateDailyTripStops(timetable, timetableIndex)
}

func validateDailyTripStops(timetable busmodel.RawDailyTimetable, timetableIndex int) error {
	trip := timetable.Timetables[timetableIndex]
	for stopIndex := range trip.StopTimes {
		if err := validateBusDailyStop(timetable, timetableIndex, stopIndex); err != nil {
			return err
		}
	}
	return nil
}

func validateBusDailyStop(timetable busmodel.RawDailyTimetable, timetableIndex, stopIndex int) error {
	stop := timetable.Timetables[timetableIndex].StopTimes[stopIndex]
	prefix := fmt.Sprintf("Timetables element %d StopTimes element %d", timetableIndex, stopIndex)
	if err := validateDailyStopIdentity(stop.StopSequence, stop.StopUID, prefix); err != nil {
		return err
	}
	return validateDailyStopClocks(stop.ArrivalTime, stop.DepartureTime, prefix)
}

func validateDailyStopIdentity(sequence int64, uid, prefix string) error {
	if sequence <= 0 || sequence > 1<<31-1 {
		return _oops.With("prefix", prefix).With("max", int64(1<<31-1)).Errorf("StopSequence out of range")
	}
	if strings.TrimSpace(uid) == "" {
		return _oops.With("prefix", prefix).Errorf("StopUID is required")
	}
	return nil
}

func validateDailyStopClocks(arrival, departure, prefix string) error {
	if !pipeline.ValidClock(arrival) {
		return _oops.With("prefix", prefix).With("arrival_time", arrival).Errorf("ArrivalTime is invalid")
	}
	if !pipeline.ValidClock(departure) {
		return _oops.With("prefix", prefix).With("departure_time", departure).Errorf("DepartureTime is invalid")
	}
	return nil
}

func canonicalBusDailyIdentity(city, subRouteUID string, direction uint8) (string, uint8, error) {
	prefix, err := busDailyCityPrefix(city)
	if err != nil {
		return "", 0, err
	}
	uid, dir := shared.CanonicalSubroute(city, subRouteUID, direction)
	if err := validateCanonicalDailyIdentity(city, subRouteUID, uid, dir, prefix); err != nil {
		return "", 0, err
	}
	return uid, dir, nil
}

func busDailyCityPrefix(city string) (string, error) {
	prefix, ok := busmodel.CityPrefix[city]
	if !ok || prefix == "" {
		return "", _oops.With("city", city).Errorf("bus daily timetable: authority is unknown")
	}
	return prefix, nil
}

func validateCanonicalDailyIdentity(city, originalUID, uid string, dir uint8, prefix string) error {
	if err := validateCanonicalDailyFields(city, originalUID, uid, dir); err != nil {
		return err
	}
	if !uidBelongsToPrefix(uid, prefix) {
		return _oops.With("city", city).With("uid", uid).With("prefix", prefix).Errorf("bus daily timetable: canonical SubRouteUID does not belong to authority")
	}
	return nil
}

func validateCanonicalDailyFields(city, originalUID, uid string, dir uint8) error {
	if strings.TrimSpace(uid) == "" {
		return _oops.With("city", city).With("sub_route_uid", originalUID).Errorf("bus daily timetable: canonical SubRouteUID is empty")
	}
	if dir > 1 {
		return _oops.With("city", city).With("dir", dir).Errorf("bus daily timetable: canonical Direction must be 0 or 1")
	}
	return nil
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
		merged = appendBusFarePayload(merged, seen, payload)
	}
	return encodeBusFareEntries(merged)
}

func appendBusFarePayload(merged []json.RawMessage, seen map[string]struct{}, payload []byte) []json.RawMessage {
	var entries []json.RawMessage
	if err := json.Unmarshal(payload, &entries); err != nil {
		return merged
	}
	for _, entry := range entries {
		if acceptBusFareEntry(seen, entry) {
			merged = append(merged, entry)
		}
	}
	return merged
}

func acceptBusFareEntry(seen map[string]struct{}, entry json.RawMessage) bool {
	key := canonicalBusFareEntry(entry)
	if key == nil {
		return false
	}
	if _, duplicate := seen[string(key)]; duplicate {
		return false
	}
	seen[string(key)] = struct{}{}
	return true
}

func encodeBusFareEntries(merged []json.RawMessage) []byte {
	if len(merged) == 0 {
		return nil
	}
	out, err := json.Marshal(merged)
	if err != nil {
		return nil
	}
	return out
}

func canonicalBusFareEntry(entry json.RawMessage) []byte {
	var canon map[string]any
	if err := json.Unmarshal(entry, &canon); err != nil {
		return nil
	}
	key, err := json.Marshal(canon)
	if err != nil {
		return nil
	}
	return key
}

func executeBusDailyWrites(ctx context.Context, pipe redis.Pipeliner, city string) error {
	if err := ctx.Err(); err != nil {
		pipe.Discard()
		return _oops.With("city", city).Wrapf(err, "bus daily timetable context before Redis transaction")
	}
	_, execErr := pipe.Exec(ctx)
	return finishBusDailyWrites(ctx, execErr, city)
}

func finishBusDailyWrites(ctx context.Context, execErr error, city string) error {
	if ctxErr := ctx.Err(); ctxErr != nil {
		return _oops.With("city", city).Wrapf(errors.Join(ctxErr, execErr), "bus daily timetable context during Redis transaction")
	}
	if execErr != nil {
		return _oops.With("city", city).Wrapf(execErr, "bus daily timetable Redis transaction")
	}
	return nil
}
