package bus

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"strings"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"google.golang.org/protobuf/proto"
)

func (s *busCitySnapshot) buildWriteRows() error {
	for _, uid := range pipeline.SortedKeys(s.subroutes) {
		if err := s.buildSubrouteRows(uid); err != nil {
			return err
		}
	}
	return nil
}
func (s *busCitySnapshot) buildSubrouteRows(uid string) error {
	sub := s.subroutes[uid]
	// Only the served payload is split; every other row keeps the loop as TDX
	// publishes it, which is what live estimates and the GTFS feed key on.
	view, turnaround := sub, turnaroundSequence(sub, s.turnarounds[uid])
	if turnaround > 0 {
		view = splitAtTurnaround(sub, turnaround)
	}
	pb, err := (proto.MarshalOptions{Deterministic: true}).Marshal(view)
	if err != nil {
		return _oops.With("uid", uid).Wrapf(err, "marshal protobuf")
	}
	s.staticRows = append(s.staticRows, []any{sub.SubRouteName, sub.RouteName, sub.SubRouteUID, sub.RouteUID, sub.City, sub.DepartureStopName, sub.DestinationStopName, pb, nullableSequence(turnaround)})
	return s.buildSubrouteDirections(uid, sub)
}

func nullableSequence(seq int32) *int32 {
	if seq == 0 {
		return nil
	}
	return &seq
}

func sortedBusDirections(sub *models.BusSubroute) []int {
	dirs := make([]int, 0, len(sub.Directions))
	for dir := range sub.Directions {
		dirs = append(dirs, int(dir))
	}
	sort.Ints(dirs)
	return dirs
}

func (s *busCitySnapshot) buildSubrouteDirections(uid string, sub *models.BusSubroute) error {
	dirs := sortedBusDirections(sub)
	for _, rawDir := range dirs {
		dir := int32(rawDir)
		if err := s.buildDirectionRows(uid, dir, sub); err != nil {
			return err
		}
	}
	return nil
}
func (s *busCitySnapshot) buildDirectionRows(uid string, dir int32, sub *models.BusSubroute) error {
	direction := sub.Directions[dir]
	stops, err := json.Marshal(direction.Stops)
	if err != nil {
		return _oops.With("uid", uid).With("dir", dir).Wrapf(err, "marshal / stops")
	}
	schedules, err := json.Marshal(direction.Schedules)
	if err != nil {
		return _oops.With("uid", uid).With("dir", dir).Wrapf(err, "marshal / schedules")
	}
	return s.appendDirectionRows(uid, dir, sub, direction, stops, schedules)
}

func marshalBusOperators(uid string, sub *models.BusSubroute) ([]byte, error) {
	ops := make([]busmodel.OperatorJSON, 0, len(sub.Operators))
	for _, op := range sub.Operators {
		ops = append(ops, busmodel.OperatorJSON{ID: op.OperatorId, Name: op.OperatorName, Phone: op.OperatorPhone, URL: op.OperatorUrl})
	}
	operators, err := json.Marshal(ops)
	if err != nil {
		return nil, _oops.With("uid", uid).Wrapf(err, "marshal operators")
	}
	return operators, nil
}

func (s *busCitySnapshot) appendDirectionRows(uid string, dir int32, sub *models.BusSubroute, direction *models.Direction, stops, schedules []byte) error {
	operators, err := marshalBusOperators(uid, sub)
	if err != nil {
		return err
	}
	s.subrouteRows = append(s.subrouteRows, []any{
		sub.SubRouteUID, sub.RouteUID, dir, sub.RouteName, sub.SubRouteName, sub.City,
		direction.DepartureStopName, direction.DestinationStopName, direction.Geometry,
		stops, schedules, operators,
	})
	s.appendDirectionStopMap(dir, sub, direction)
	return nil
}

func (s *busCitySnapshot) appendDirectionStopMap(dir int32, sub *models.BusSubroute, direction *models.Direction) {
	for _, stop := range direction.Stops {
		s.stopMapRows = append(s.stopMapRows, []any{
			prefixID(s.prefix, stop.StationID), stop.StopName, sub.SubRouteUID,
			sub.SubRouteName, dir, stop.StopUID, stop.StopSequence,
		})
	}
}

func busStopAliasRows(uid string, dir uint8, kept, discarded busmodel.RawStopOfRoute) [][]any {
	keptBySequence := make(map[uint8]string, len(kept.Stops))
	for _, stop := range kept.Stops {
		keptBySequence[stop.StopSequence] = stop.StopUID
	}
	return discardedStopAliases(uid, dir, keptBySequence, discarded)
}

func discardedStopAliases(uid string, dir uint8, keptBySequence map[uint8]string, discarded busmodel.RawStopOfRoute) [][]any {
	rows := make([][]any, 0, len(discarded.Stops))
	for _, stop := range discarded.Stops {
		canonical, ok := keptBySequence[stop.StopSequence]
		if !ok || canonical == stop.StopUID {
			continue
		}
		rows = append(rows, []any{uid, int16(dir), stop.StopUID, canonical})
	}
	return rows
}

type busScheduleRows struct {
	uid       string
	dir       uint8
	rows      [][]any
	modelRows []*models.Bus_Schedule
}

func buildScheduleRows(uid string, dir uint8, schedule busmodel.RawSchedule) ([][]any, []*models.Bus_Schedule, error) {
	b := busScheduleRows{uid: uid, dir: dir}
	if err := b.addTimetables(schedule); err != nil {
		return nil, nil, err
	}
	if err := b.addFrequencies(schedule); err != nil {
		return nil, nil, err
	}
	return b.rows, b.modelRows, nil
}
func (b *busScheduleRows) addTimetable(schedule busmodel.RawSchedule, ti int) error {
	timetable := schedule.Timetables[ti]
	if timetable.TripID == "" {
		return errors.New("timetable has empty TripID")
	}
	service := pipeline.Mask2(timetable.ServiceDay.Monday, timetable.ServiceDay.Tuesday, timetable.ServiceDay.Wednesday, timetable.ServiceDay.Thursday, timetable.ServiceDay.Friday, timetable.ServiceDay.Saturday, timetable.ServiceDay.Sunday)
	return b.addTimetableStops(schedule, ti, service)
}

func (b *busScheduleRows) addTimetableStops(schedule busmodel.RawSchedule, ti int, service uint8) error {
	uid, dir, timetable := b.uid, b.dir, schedule.Timetables[ti]
	var origin *models.Bus_Schedule
	var originSeq int
	for si, stop := range timetable.StopTimes {
		if err := validateBusTimetableStop(schedule, ti, si); err != nil {
			return err
		}
		b.rows = append(b.rows, []any{uid, int16(dir), false, timetable.TripID, timetable.IsLowFloor, int16(stop.StopSequence), stop.StopUID, stop.StopName.Zhtw, stop.ArrivalTime, stop.DepartureTime, int16(service)})
		origin, originSeq = selectTimetableOrigin(schedule, ti, si, service, origin, originSeq)
	}
	b.appendTimetableOrigin(origin)
	return nil
}
func validateBusTimetableStop(schedule busmodel.RawSchedule, ti, si int) error {
	timetable := schedule.Timetables[ti]
	stop := timetable.StopTimes[si]
	// The upper bound is the bus_schedule.stop_sequence SMALLINT column: an
	// out-of-range sequence would wrap to a negative on the int16 cast below.
	seqInRange := timetableStopSequenceInRange(stop.StopSequence)
	hasIdentity := hasTimetableStopIdentity(stop.StopUID, stop.StopName.Zhtw)
	hasClocks := validTimetableClockPair(stop.ArrivalTime, stop.DepartureTime)
	if !validTimetableStopFields(seqInRange, hasIdentity, hasClocks) {
		return _oops.With("trip_id", timetable.TripID).Errorf("trip has invalid stop identity/sequence/time")
	}
	return nil
}
func (b *busScheduleRows) addFrequency(schedule busmodel.RawSchedule, fi int) error {
	uid, dir, frequency := b.uid, b.dir, schedule.Frequencys[fi]
	hasClocks := validTimetableClockPair(frequency.StartTime, frequency.EndTime)
	hasHeadway := validFrequencyHeadway(frequency.MinHeadwayMins, frequency.MaxHeadwayMins)
	if !hasClocks || !hasHeadway {
		return errors.New("frequency has invalid time/headway")
	}
	service := pipeline.Mask2(frequency.ServiceDay.Monday, frequency.ServiceDay.Tuesday, frequency.ServiceDay.Wednesday, frequency.ServiceDay.Thursday, frequency.ServiceDay.Friday, frequency.ServiceDay.Saturday, frequency.ServiceDay.Sunday)
	b.rows = append(b.rows, []any{uid, int16(dir), true, "", false, int16(-1), fmt.Sprint(frequency.MinHeadwayMins), fmt.Sprint(frequency.MaxHeadwayMins), frequency.StartTime, frequency.EndTime, int16(service)})
	b.modelRows = append(b.modelRows, &models.Bus_Schedule{
		IsTimetable: false, Start_Time: frequency.StartTime, End_Time: frequency.EndTime,
		MinHeadwayMinsArrivalTime: fmt.Sprint(frequency.MinHeadwayMins), MaxHeadwayMinsDepartureTime: fmt.Sprint(frequency.MaxHeadwayMins),
		ServiceDay: int32(service),
	})
	return nil
}

func decodeStrictJSONArray(body []byte, target any) error {
	trimmed := bytes.TrimSpace(body)
	if !isJSONArrayFrame(trimmed) {
		return errors.New("payload is not a JSON array")
	}
	dec := json.NewDecoder(bytes.NewReader(trimmed))
	if err := dec.Decode(target); err != nil {
		return err
	}
	return validateJSONArrayEnd(dec)
}

func validateJSONArrayEnd(dec *json.Decoder) error {
	var trailing json.RawMessage
	err := dec.Decode(&trailing)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("trailing JSON value")
	}
	return _oops.Wrapf(err, "malformed trailing JSON")
}

func normalizeClock(value string) (string, bool) {
	v := strings.TrimSpace(value)
	v = expandBusClock(v)
	if !validBusClockFrame(v) {
		return "", false
	}
	h := int(v[0]-'0')*10 + int(v[1]-'0')
	m := int(v[3]-'0')*10 + int(v[4]-'0')
	if h > 29 || m > 59 {
		return "", false
	}
	return v, true
}

func validBusClockDigits(v string) bool {
	for _, i := range [...]int{0, 1, 3, 4} {
		if v[i] < '0' || v[i] > '9' {
			return false
		}
	}
	return true
}

func prefixID(prefix, id string) string {
	if id == "" || strings.HasPrefix(id, prefix) {
		return id
	}
	return prefix + id
}

func uidBelongsToPrefix(uid, prefix string) bool {
	return uid != "" && prefix != "" && strings.HasPrefix(uid, prefix)
}

func applySubrouteEndpoints(sub *models.BusSubroute) {
	direction := sub.Directions[0]
	if direction == nil {
		direction = sub.Directions[1]
	}
	if direction == nil {
		return
	}
	sub.DepartureStopName = direction.DepartureStopName
	sub.DestinationStopName = direction.DestinationStopName
}

func normalizeStationName(name string) string {
	return strings.TrimSuffix(name, "(市區公車)")
}

func manualGroupUID(city, name string) string {
	sum := md5.Sum([]byte(name))
	return city + ":manual:" + hex.EncodeToString(sum[:])
}

func directionFor(routes map[string]*models.BusSubroute, uid string, dir uint8) *models.Direction {
	if route := routes[uid]; route != nil {
		return route.Directions[int32(dir)]
	}
	return nil
}

func appendUniqueOperator(operators []*models.BusOperator, candidate *models.BusOperator) []*models.BusOperator {
	for _, operator := range operators {
		if operator.OperatorId == candidate.OperatorId {
			return operators
		}
	}
	return append(operators, candidate)
}

func jsonSemanticEqual(a, b any) bool {
	left, err := json.Marshal(a)
	if err != nil {
		return false
	}
	right, err := json.Marshal(b)
	return err == nil && bytes.Equal(left, right)
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

func (b *busScheduleRows) addTimetables(schedule busmodel.RawSchedule) error {
	for i := range schedule.Timetables {
		if err := b.addTimetable(schedule, i); err != nil {
			return err
		}
	}
	return nil
}

func (b *busScheduleRows) addFrequencies(schedule busmodel.RawSchedule) error {
	for i := range schedule.Frequencys {
		if err := b.addFrequency(schedule, i); err != nil {
			return err
		}
	}
	return nil
}

func selectTimetableOrigin(schedule busmodel.RawSchedule, ti, si int, service uint8, origin *models.Bus_Schedule, originSeq int) (*models.Bus_Schedule, int) {
	timetable := schedule.Timetables[ti]
	stop := timetable.StopTimes[si]
	if origin != nil && stop.StopSequence >= originSeq {
		return origin, originSeq
	}
	originSeq = stop.StopSequence
	origin = &models.Bus_Schedule{
		IsTimetable: true, Tripid: timetable.TripID, Islowfloor: timetable.IsLowFloor,
		MinHeadwayMinsArrivalTime: stop.ArrivalTime, MaxHeadwayMinsDepartureTime: stop.DepartureTime,
		ServiceDay: int32(service),
	}
	return origin, originSeq
}

func hasTimetableStopIdentity(uid, name string) bool { return uid != "" && name != "" }
func timetableStopSequenceInRange(sequence int) bool {
	return sequence > 0 && sequence <= math.MaxInt16
}
func validTimetableClockPair(arrival, departure string) bool {
	return pipeline.ValidClock(arrival) && pipeline.ValidClock(departure)
}
func validFrequencyHeadway(minimum, maximum uint8) bool { return minimum != 0 && maximum >= minimum }

func isJSONArrayFrame(value []byte) bool {
	return len(value) >= 2 && value[0] == '[' && value[len(value)-1] == ']'
}

func expandBusClock(value string) string {
	if len(value) == 4 && value[2] != ':' {
		return value[:2] + ":" + value[2:]
	}
	return value
}
func validBusClockFrame(value string) bool {
	if len(value) != 5 || value[2] != ':' {
		return false
	}
	return validBusClockDigits(value)
}

func validTimetableStopFields(sequence, identity, clocks bool) bool {
	return sequence && identity && clocks
}

func (b *busScheduleRows) appendTimetableOrigin(origin *models.Bus_Schedule) {
	if origin != nil {
		b.modelRows = append(b.modelRows, origin)
	}
}
