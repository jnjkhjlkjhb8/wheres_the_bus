package bus

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/raw"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

var (
	errBusSnapshotIncomplete = errors.New("bus city snapshot incomplete")
	errBusSnapshotConflict   = errors.New("bus city snapshot conflict")
	errBusSnapshotInvalid    = errors.New("bus city snapshot invalid")
)

type rawBusStation struct {
	StationUID  string `json:"stationuid"`
	StationID   string `json:"stationid"`
	StationName struct {
		Zhtw string `json:"Zh_tw"`
	} `json:"stationname"`
	StationPosition struct {
		PositionLon float64 `json:"PositionLon"`
		PositionLat float64 `json:"PositionLat"`
	} `json:"stationposition"`
	StationGroupID string `json:"stationgroupid"`
}

type rawBusStationGroup struct {
	StationGroupUID  string `json:"stationgroupuid"`
	StationGroupID   string `json:"stationgroupid"`
	StationGroupName struct {
		Zhtw string `json:"Zh_tw"`
	} `json:"stationgroupname"`
	StationGroupPosition struct {
		PositionLon float64 `json:"PositionLon"`
		PositionLat float64 `json:"PositionLat"`
	} `json:"stationgroupposition"`
}

// busCitySnapshot is a complete, validated, write-ready city replacement.
// Every JSON/protobuf value is built before a target transaction starts.
type busCitySnapshot struct {
	city         string
	prefix       string
	landingCycle string
	subroutes    map[string]*models.BusSubroute
	operatorRows [][]any
	subrouteRows [][]any
	stationRows  [][]any
	groupRows    [][]any
	memberRows   [][]any
	scheduleRows [][]any
	staticRows   [][]any
	stopMapRows  [][]any
	aliasRows    [][]any
}

func readBusCitySnapshot(ctx context.Context, src pipeline.LoadSource, city string) (*busCitySnapshot, error) {
	if src == nil {
		return nil, _oops.Wrapf(errBusSnapshotIncomplete, "nil source")
	}
	prefix := busmodel.CityPrefix[city]
	if prefix == "" {
		return nil, _oops.With("city", city).Wrapf(errBusSnapshotInvalid, "city has no UID prefix")
	}
	cycleSource, ok := src.(raw.LandingCycleSource)
	if !ok {
		return nil, _oops.Wrapf(errBusSnapshotIncomplete, "source cannot return an atomic landing cycle")
	}
	q := pipeline.NewQuarantine("bus", city)
	defer q.Report()
	landingCycle := ""
	readDataset := func(table string) ([]byte, error) {
		body, cycle, err := readBusRawDataset(ctx, cycleSource, city, table)
		if err != nil {
			return nil, err
		}
		if landingCycle == "" {
			landingCycle = cycle
		} else if cycle != landingCycle {
			return nil, _oops.With("table", table).With("city", city).With("cycle", cycle).With("landing_cycle", landingCycle).Wrapf(errBusSnapshotIncomplete, "landing cycle does not match")
		}
		return body, nil
	}
	var operators []busmodel.RawOperator
	operatorBody, err := readDataset("bus_operator")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(operatorBody, &operators); err != nil {
		return nil, _oops.Wrapf(err, "Operator")
	}
	opByID := make(map[string]busmodel.RawOperator, len(operators))
	for i, op := range operators {
		hasID := strings.TrimSpace(op.OperatorID) != ""
		hasName := strings.TrimSpace(op.OperatorName.Zhtw) != ""
		hasAuthority := strings.TrimSpace(op.AuthorityCode) != ""
		if !hasID || !hasName || !hasAuthority {
			return nil, _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "Operator has incomplete identity")
		}
		if op.AuthorityCode != prefix {
			return nil, _oops.With("index", i).With("authority_code", op.AuthorityCode).With("city", city).Wrapf(errBusSnapshotInvalid, "Operator authority does not belong")
		}
		if old, ok := opByID[op.OperatorID]; ok && !jsonSemanticEqual(old, op) {
			return nil, _oops.With("operator_id", op.OperatorID).Wrapf(errBusSnapshotConflict, "OperatorID has divergent variants")
		}
		opByID[op.OperatorID] = op
	}

	var routes []busmodel.RawRoute
	routeBody, err := readDataset("bus_route")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(routeBody, &routes); err != nil {
		return nil, _oops.Wrapf(err, "Route")
	}
	snapshot := &busCitySnapshot{city: city, prefix: prefix, landingCycle: landingCycle, subroutes: make(map[string]*models.BusSubroute)}
	operatorIDs := make([]string, 0, len(opByID))
	for operatorID := range opByID {
		operatorIDs = append(operatorIDs, operatorID)
	}
	sort.Strings(operatorIDs)
	for _, operatorID := range operatorIDs {
		op := opByID[operatorID]
		snapshot.operatorRows = append(snapshot.operatorRows, []any{
			op.OperatorID, op.AuthorityCode, op.OperatorName.Zhtw,
			sanitizeOperatorPhone(op.OperatorPhone), op.OperatorURL,
		})
	}
	subrouteCount := 0
	for _, r := range routes {
		subrouteCount += len(r.SubRoutes)
	}
	q.Consider("subroute", subrouteCount)
	routeToCanonical := make(map[string]map[string]struct{})
	nativeToCanonical := make(map[string]string)
	for ri, route := range routes {
		hasUID := strings.TrimSpace(route.RouteUID) != ""
		hasName := strings.TrimSpace(route.RouteName.Zhtw) != ""
		if !hasUID || !hasName || len(route.SubRoutes) == 0 {
			return nil, _oops.With("route_index", ri).Wrapf(errBusSnapshotInvalid, "Route missing route identity or subroutes")
		}
		if !uidBelongsToPrefix(route.RouteUID, prefix) {
			return nil, _oops.With("route_index", ri).With("route_uid", route.RouteUID).With("city", city).Wrapf(errBusSnapshotInvalid, "Route UID does not belong")
		}
		var ops []*models.BusOperator
		for _, ref := range route.Operators {
			op, ok := opByID[ref.OperatorID]
			if !ok {
				return nil, _oops.With("route_uid", route.RouteUID).With("operator_id", ref.OperatorID).Wrapf(errBusSnapshotInvalid, "Route references unknown operator")
			}
			ops = appendUniqueOperator(ops, &models.BusOperator{
				OperatorId: ref.OperatorID, OperatorName: op.OperatorName.Zhtw,
				OperatorPhone: sanitizeOperatorPhone(op.OperatorPhone), OperatorUrl: op.OperatorURL,
			})
		}
		for si, sub := range route.SubRoutes {
			uid, dir := shared.CanonicalSubroute(city, sub.SubRouteUID, sub.Direction)
			hasCanonicalUID := strings.TrimSpace(uid) != ""
			hasNativeUID := strings.TrimSpace(sub.SubRouteUID) != ""
			hasSubName := strings.TrimSpace(sub.SubRouteName.Zhtw) != ""
			if !hasCanonicalUID || !hasNativeUID || !hasSubName || dir > 1 {
				// Unusable identity: nothing downstream can key off this
				// subroute, so it goes rather than the city.
				q.Drop("subroute", "subroute_identity", fmt.Sprintf("Route[%d].SubRoutes[%d] uid=%q dir=%d", ri, si, sub.SubRouteUID, sub.Direction))
				continue
			}
			if !uidBelongsToPrefix(sub.SubRouteUID, prefix) || !uidBelongsToPrefix(uid, prefix) {
				return nil, _oops.With("route_index", ri).With("subroute_index", si).With("sub_route_uid", sub.SubRouteUID).With("uid", uid).With("city", city).Wrapf(errBusSnapshotInvalid, "Route.SubRoutes UID canonical does not belong")
			}
			for _, f := range []struct {
				label string
				value *string
			}{
				{label: "FirstBusTime", value: &sub.FirstBusTime}, {label: "LastBusTime", value: &sub.LastBusTime},
				{label: "HolidayFirstBusTime", value: &sub.HolidayFirstBusTime}, {label: "HolidayLastBusTime", value: &sub.HolidayLastBusTime},
			} {
				if *f.value == "" {
					continue
				}
				norm, ok := normalizeClock(*f.value)
				if !ok {
					q.Drop("subroute", "subroute_clock", fmt.Sprintf("%s/%d %s=%q", uid, dir, f.label, *f.value))
					*f.value = ""
					continue
				}
				*f.value = norm
			}
			dep, dest := sub.DepartureStopNameZh, sub.DestinationStopNameZh
			if dep == "" {
				dep = route.DepartureStopNameZh
			}
			if dest == "" {
				dest = route.DestinationStopNameZh
			}
			if dir == 1 {
				dep, dest = dest, dep
			}
			candidate := &models.Direction{
				DepartureStopName: dep, DestinationStopName: dest,
				FirstBusTime: sub.FirstBusTime, LastBusTime: sub.LastBusTime,
				HolidayFirstBusTime: sub.HolidayFirstBusTime, HolidayLastBusTime: sub.HolidayLastBusTime,
			}
			existing := snapshot.subroutes[uid]
			if existing == nil {
				existing = &models.BusSubroute{
					RouteUID: route.RouteUID, RouteName: route.RouteName.Zhtw,
					SubRouteUID: uid, SubRouteName: sub.SubRouteName.Zhtw, City: city,
					DepartureStopName: dep, DestinationStopName: dest,
					Directions: make(map[int32]*models.Direction), Operators: ops,
				}
				snapshot.subroutes[uid] = existing
			} else {
				sameRouteUID := existing.RouteUID == route.RouteUID
				sameRouteName := existing.RouteName == route.RouteName.Zhtw
				sameSubName := existing.SubRouteName == sub.SubRouteName.Zhtw
				if !sameRouteUID || !sameRouteName || !sameSubName {
					return nil, _oops.With("uid", uid).Wrapf(errBusSnapshotConflict, "canonical route has divergent route/name variants")
				}
				for _, op := range ops {
					existing.Operators = appendUniqueOperator(existing.Operators, op)
				}
			}
			if prior := existing.Directions[int32(dir)]; prior != nil && !proto.Equal(prior, candidate) {
				return nil, _oops.With("uid", uid).With("dir", dir).Wrapf(errBusSnapshotConflict, "canonical route direction has divergent route variants")
			}
			if existing.Directions[int32(dir)] == nil {
				existing.Directions[int32(dir)] = candidate
			}
			if routeToCanonical[route.RouteUID] == nil {
				routeToCanonical[route.RouteUID] = make(map[string]struct{})
			}
			routeToCanonical[route.RouteUID][uid] = struct{}{}
			for _, native := range []string{sub.SubRouteUID, sub.SubRouteID, prefixID(prefix, sub.SubRouteID)} {
				if native != "" {
					if mapped := nativeToCanonical[native]; mapped != "" && mapped != uid {
						return nil, _oops.With("native", native).With("mapped", mapped).With("uid", uid).Wrapf(errBusSnapshotConflict, "native subroute maps to both")
					}
					nativeToCanonical[native] = uid
				}
			}
		}
	}
	if len(snapshot.subroutes) == 0 {
		return nil, _oops.Wrapf(errBusSnapshotInvalid, "Route produced zero canonical subroutes")
	}
	for _, sub := range snapshot.subroutes {
		sort.Slice(sub.Operators, func(i, j int) bool {
			return sub.Operators[i].OperatorId < sub.Operators[j].OperatorId
		})
		applySubrouteEndpoints(sub)
	}

	var stopVariants []busmodel.RawStopOfRoute
	stopBody, err := readDataset("bus_stopofroute")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(stopBody, &stopVariants); err != nil {
		return nil, _oops.Wrapf(err, "StopOfRoute")
	}
	q.Consider("stopofroute", len(stopVariants))
	unsurveyedStops := 0
	seenStops := make(map[string]busmodel.RawStopOfRoute)
	for i, variant := range stopVariants {
		uid, dir := shared.CanonicalSubroute(city, variant.SubRouteUID, variant.Direction)
		route := snapshot.subroutes[uid]
		direction := directionFor(snapshot.subroutes, uid, dir)
		if !uidBelongsToPrefix(variant.RouteUID, prefix) || !uidBelongsToPrefix(variant.SubRouteUID, prefix) {
			return nil, _oops.With("index", i).With("sub_route_uid", variant.SubRouteUID).With("city", city).Wrapf(errBusSnapshotInvalid, "StopOfRoute UID does not belong")
		}
		if !uidBelongsToPrefix(uid, prefix) || route == nil || direction == nil {
			// Dangling reference: the parent subroute was never published, or
			// was itself dropped above. Nothing to attach these stops to.
			q.Drop("stopofroute", "stopofroute_dangling", fmt.Sprintf("StopOfRoute[%d] -> %s/%d", i, uid, dir))
			continue
		}
		if variant.RouteUID != route.RouteUID {
			return nil, _oops.With("index", i).With("route_uid", variant.RouteUID).With("route_uid_2", route.RouteUID).With("uid", uid).Wrapf(errBusSnapshotInvalid, "StopOfRoute parent does not match")
		}
		if len(variant.Stops) == 0 {
			return nil, _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "StopOfRoute has no stops")
		}
		lastSequence := uint8(0)
		unordered := false
		for j, stop := range variant.Stops {
			hasStopUID := strings.TrimSpace(stop.StopUID) != ""
			hasStopName := strings.TrimSpace(stop.StopName.Zhtw) != ""
			hasStationID := strings.TrimSpace(stop.StationID) != ""
			if !hasStopUID || !hasStopName || !hasStationID || stop.StopSequence == 0 {
				return nil, _oops.With("index", i).With("index_2", j).Wrapf(errBusSnapshotInvalid, "StopOfRoute.Stops has invalid identity/sequence")
			}
			if !pipeline.ValidPosition(stop.StopPosition.PositionLon, stop.StopPosition.PositionLat) {
				unsurveyedStops++
			}
			if stop.StopSequence <= lastSequence {
				q.Drop("stopofroute", "stopofroute_unordered", fmt.Sprintf("StopOfRoute[%d] %s/%d seq=%d", i, uid, dir, stop.StopSequence))
				unordered = true
				break
			}
			lastSequence = stop.StopSequence
		}
		if unordered {
			continue
		}
		key := fmt.Sprintf("%s/%d", uid, dir)
		if prior, ok := seenStops[key]; ok {
			if !jsonSemanticEqual(prior.Stops, variant.Stops) {
				q.Drop("stopofroute", "stopofroute_divergent", key)
			}
			// The list is not kept, but its StopUIDs are: N1 keys each estimate on
			// the StopID of the operator that runs it, so without the alias every
			// arrival published under the discarded list matches no stop at all.
			snapshot.aliasRows = append(snapshot.aliasRows,
				busStopAliasRows(uid, dir, prior, variant)...)
			continue
		}
		seenStops[key] = variant
		for _, stop := range variant.Stops {
			direction.Stops = append(direction.Stops, &models.BusStop{
				StopName: stop.StopName.Zhtw, StopSequence: int32(stop.StopSequence),
				PositionLat: stop.StopPosition.PositionLat, PositionLon: stop.StopPosition.PositionLon,
				StationID: stop.StationID, StopUID: stop.StopUID,
			})
		}
	}
	for _, uid := range pipeline.SortedKeys(snapshot.subroutes) {
		sub := snapshot.subroutes[uid]
		pruned := false
		for _, dir := range []int32{0, 1} {
			if direction := sub.Directions[dir]; direction != nil && len(direction.Stops) == 0 {
				q.Drop("stopofroute", "stopofroute_missing", fmt.Sprintf("%s/%d", uid, dir))
				delete(sub.Directions, dir)
				pruned = true
			}
		}
		if !pruned {
			continue
		}
		if len(sub.Directions) == 0 {
			delete(snapshot.subroutes, uid)
			continue
		}
		// The surviving direction now owns the subroute-level endpoints.
		applySubrouteEndpoints(sub)
	}
	if len(snapshot.subroutes) == 0 {
		return nil, _oops.Wrapf(errBusSnapshotInvalid, "every canonical subroute lost its StopOfRoute")
	}

	var shapes []busmodel.RawShape
	shapeBody, err := readDataset("bus_shape")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(shapeBody, &shapes); err != nil {
		return nil, _oops.Wrapf(err, "Shape")
	}
	q.Consider("shape", len(shapes))
	seenShapes := make(map[string]string)
	for i, shape := range shapes {
		if strings.TrimSpace(shape.Geometry) == "" {
			return nil, _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "Shape has empty Geometry")
		}
		var targets []string
		if shape.SubRouteUID != "" {
			uid, _ := shared.CanonicalSubroute(city, shape.SubRouteUID, shape.Direction)
			ownRoute := uidBelongsToPrefix(shape.RouteUID, prefix)
			ownNativeSub := uidBelongsToPrefix(shape.SubRouteUID, prefix)
			ownCanonicalSub := uidBelongsToPrefix(uid, prefix)
			if !ownRoute || !ownNativeSub || !ownCanonicalSub {
				return nil, _oops.With("index", i).With("city", city).Wrapf(errBusSnapshotInvalid, "Shape subroute UID does not belong")
			}
			targets = []string{uid}
		} else {
			if !uidBelongsToPrefix(shape.RouteUID, prefix) {
				return nil, _oops.With("index", i).With("city", city).Wrapf(errBusSnapshotInvalid, "Shape route UID does not belong")
			}
			for uid := range routeToCanonical[shape.RouteUID] {
				targets = append(targets, uid)
			}
		}
		if len(targets) == 0 {
			// A shape whose RouteUID is absent from bus_route entirely.
			// Geometry is the map polyline only, so the route stays fully
			// usable without it.
			q.Drop("shape", "shape_unknown_route", fmt.Sprintf("Shape[%d]->route:%s", i, shape.RouteUID))
			continue
		}
		for _, uid := range targets {
			_, dir := shared.CanonicalSubroute(city, shape.SubRouteUID, shape.Direction)
			route := snapshot.subroutes[uid]
			direction := directionFor(snapshot.subroutes, uid, dir)
			if direction == nil || route == nil {
				scope := "sub"
				if shape.SubRouteUID == "" {
					scope = "routelevel"
				}
				q.Drop("shape", "shape_unknown_direction", fmt.Sprintf("Shape[%d]/%s->%s/%d", i, scope, uid, dir))
				continue
			}
			// A parent mismatch is a payload-integrity signal, not a per-record
			// defect: it stays fatal alongside the foreign-UID checks.
			if shape.RouteUID != "" && shape.RouteUID != route.RouteUID {
				return nil, _oops.With("index", i).With("route_uid", shape.RouteUID).With("route_uid_2", route.RouteUID).With("uid", uid).Wrapf(errBusSnapshotInvalid, "Shape parent does not match")
			}
			key := fmt.Sprintf("%s/%d", uid, dir)
			if prior, ok := seenShapes[key]; ok && prior != shape.Geometry {
				// First variant wins, as for StopOfRoute above.
				q.Drop("shape", "shape_divergent", key)
				continue
			}
			seenShapes[key] = shape.Geometry
			direction.Geometry = shape.Geometry
		}
	}

	var schedules []busmodel.RawSchedule
	scheduleBody, err := readDataset("bus_schedule")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(scheduleBody, &schedules); err != nil {
		return nil, _oops.Wrapf(err, "Schedule")
	}
	q.Consider("schedule", len(schedules))
	seenSchedules := make(map[string]busmodel.RawSchedule)
	for i, schedule := range schedules {
		uid, dir := shared.CanonicalSubroute(city, schedule.SubRouteUID, schedule.Direction)
		route := snapshot.subroutes[uid]
		direction := directionFor(snapshot.subroutes, uid, dir)
		if !uidBelongsToPrefix(schedule.RouteUID, prefix) || !uidBelongsToPrefix(schedule.SubRouteUID, prefix) {
			return nil, _oops.With("index", i).With("sub_route_uid", schedule.SubRouteUID).With("city", city).Wrapf(errBusSnapshotInvalid, "Schedule UID does not belong")
		}
		if !uidBelongsToPrefix(uid, prefix) || route == nil || direction == nil {
			q.Drop("schedule", "schedule_dangling", fmt.Sprintf("Schedule[%d] -> %s/%d", i, uid, dir))
			continue
		}
		// A parent mismatch is a payload-integrity signal, not a per-record
		// defect: it stays fatal alongside the foreign-UID checks.
		if schedule.RouteUID != route.RouteUID {
			return nil, _oops.With("index", i).With("route_uid", schedule.RouteUID).With("route_uid_2", route.RouteUID).With("uid", uid).Wrapf(errBusSnapshotInvalid, "Schedule parent does not match")
		}
		key := fmt.Sprintf("%s/%d", uid, dir)
		if prior, ok := seenSchedules[key]; ok {
			// First variant wins, as for StopOfRoute and Shape above.
			if !jsonSemanticEqual(prior, schedule) {
				q.Drop("schedule", "schedule_divergent", key)
			}
			continue
		}
		seenSchedules[key] = schedule
		rows, modelRows, err := buildScheduleRows(uid, dir, schedule)
		if err != nil {
			// One malformed timetable (an empty TripID, an unparseable stop
			// time) costs this subroute its schedule, not the city its load.
			q.Drop("schedule", "schedule_malformed", fmt.Sprintf("Schedule[%d] %s/%d: %v", i, uid, dir, err))
			continue
		}
		snapshot.scheduleRows = append(snapshot.scheduleRows, rows...)
		direction.Schedules = append(direction.Schedules, modelRows...)
	}

	var stations []rawBusStation
	stationBody, err := readDataset("bus_station")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(stationBody, &stations); err != nil {
		return nil, _oops.Wrapf(err, "Station")
	}
	stationUIDs := make(map[string]struct{}, len(stations))
	stationIDs := make(map[string]string, len(stations))
	stationsByUID := make(map[string]rawBusStation, len(stations))
	unsurveyedStations := 0
	for i, station := range stations {
		ownUID := uidBelongsToPrefix(station.StationUID, prefix)
		if !ownUID || station.StationID == "" || station.StationName.Zhtw == "" {
			return nil, _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "Station has invalid identity")
		}
		// Same pending-survey case as the stop positions above. A station cannot
		// be dropped over it: every route stop referencing it would then fail the
		// missing-station check below and take the city with it.
		if !pipeline.ValidPosition(station.StationPosition.PositionLon, station.StationPosition.PositionLat) {
			unsurveyedStations++
		}
		if prior, exists := stationsByUID[station.StationUID]; exists {
			if !jsonSemanticEqual(prior, station) {
				return nil, _oops.With("station_uid", station.StationUID).Wrapf(errBusSnapshotConflict, "StationUID has divergent variants")
			}
			continue
		}
		if priorUID := stationIDs[station.StationID]; priorUID != "" && priorUID != station.StationUID {
			return nil, _oops.With("station_id", station.StationID).With("prior_uid", priorUID).With("station_uid", station.StationUID).Wrapf(errBusSnapshotConflict, "StationID maps to both")
		}
		stationsByUID[station.StationUID] = station
		stationUIDs[station.StationUID] = struct{}{}
		stationIDs[station.StationID] = station.StationUID
		snapshot.stationRows = append(snapshot.stationRows, []any{
			station.StationUID, station.StationID, normalizeStationName(station.StationName.Zhtw),
			station.StationPosition.PositionLon, station.StationPosition.PositionLat, station.StationGroupID,
		})
	}
	stationOrder := make([]string, 0, len(stationsByUID))
	for uid := range stationsByUID {
		stationOrder = append(stationOrder, uid)
	}
	sort.Strings(stationOrder)
	uniqueStations := make([]rawBusStation, 0, len(stationOrder))
	for _, uid := range stationOrder {
		uniqueStations = append(uniqueStations, stationsByUID[uid])
	}
	for uid, sub := range snapshot.subroutes {
		for _, direction := range sub.Directions {
			for _, stop := range direction.Stops {
				fullID := prefixID(prefix, stop.StationID)
				if _, ok := stationUIDs[fullID]; !ok {
					if _, localOK := stationIDs[stop.StationID]; !localOK {
						return nil, _oops.With("uid", uid).With("stop_uid", stop.StopUID).With("station_id", stop.StationID).Wrapf(errBusSnapshotInvalid, "route stop references missing station")
					}
				}
			}
		}
	}

	var groups []rawBusStationGroup
	groupBody, err := readDataset("bus_stationgroup")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(groupBody, &groups); err != nil {
		return nil, _oops.Wrapf(err, "StationGroup")
	}
	groupsByID := make(map[string]rawBusStationGroup)
	groupsByUID := make(map[string]rawBusStationGroup)
	for i, group := range groups {
		ownUID := uidBelongsToPrefix(group.StationGroupUID, prefix)
		hasPosition := pipeline.ValidPosition(group.StationGroupPosition.PositionLon, group.StationGroupPosition.PositionLat)
		if !ownUID || group.StationGroupID == "" || group.StationGroupName.Zhtw == "" || !hasPosition {
			return nil, _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "StationGroup has invalid identity/position")
		}
		if prior, ok := groupsByID[group.StationGroupID]; ok && !jsonSemanticEqual(prior, group) {
			return nil, _oops.With("station_group_id", group.StationGroupID).Wrapf(errBusSnapshotConflict, "StationGroupID has divergent UID/payload")
		}
		if prior, ok := groupsByUID[group.StationGroupUID]; ok {
			if !jsonSemanticEqual(prior, group) {
				return nil, _oops.With("station_group_uid", group.StationGroupUID).Wrapf(errBusSnapshotConflict, "StationGroupUID has divergent variants")
			}
			continue
		}
		groupsByID[group.StationGroupID] = group
		groupsByUID[group.StationGroupUID] = group
		snapshot.groupRows = append(snapshot.groupRows, []any{
			group.StationGroupUID, group.StationGroupID, normalizeStationName(group.StationGroupName.Zhtw),
			group.StationGroupPosition.PositionLon, group.StationGroupPosition.PositionLat, "tdx",
		})
	}
	type manualGroupAggregate struct {
		name       string
		lonSum     float64
		latSum     float64
		stationCnt int
	}
	manualGroups := make(map[string]*manualGroupAggregate)
	for _, station := range uniqueStations {
		stationName := normalizeStationName(station.StationName.Zhtw)
		groupUID := ""
		if group, ok := groupsByID[station.StationGroupID]; ok {
			groupUID = group.StationGroupUID
		} else {
			groupUID = manualGroupUID(city, stationName)
			aggregate := manualGroups[groupUID]
			if aggregate == nil {
				aggregate = &manualGroupAggregate{name: stationName}
				manualGroups[groupUID] = aggregate
			}
			aggregate.lonSum += station.StationPosition.PositionLon
			aggregate.latSum += station.StationPosition.PositionLat
			aggregate.stationCnt++
		}
		snapshot.memberRows = append(snapshot.memberRows, []any{
			station.StationUID, groupUID, station.StationID, stationName,
			station.StationPosition.PositionLon, station.StationPosition.PositionLat,
		})
	}
	manualUIDs := make([]string, 0, len(manualGroups))
	for uid := range manualGroups {
		manualUIDs = append(manualUIDs, uid)
	}
	sort.Strings(manualUIDs)
	for _, uid := range manualUIDs {
		aggregate := manualGroups[uid]
		snapshot.groupRows = append(snapshot.groupRows, []any{
			uid, uid, aggregate.name,
			aggregate.lonSum / float64(aggregate.stationCnt),
			aggregate.latSum / float64(aggregate.stationCnt),
			"manual_name",
		})
	}

	var fares []busmodel.RawFare
	fareBody, err := readDataset("bus_routefare")
	if err != nil {
		return nil, err
	}
	if err := decodeStrictJSONArray(fareBody, &fares); err != nil {
		return nil, _oops.Wrapf(err, "RouteFare")
	}
	q.Consider("routefare", len(fares))
	fareCandidates := make(map[string][]*models.Bus_Fare)
	for i, rawFare := range fares {
		fare := &models.Bus_Fare{
			FarePricingType: rawFare.FarePricingType, IsFreeBus: rawFare.IsFreeBus == 1,
			SectionFaresJson: jsonOrNil(rawFare.SectionFares), StageFaresJson: jsonOrNil(rawFare.StageFares), OdFaresJson: jsonOrNil(rawFare.ODFares),
		}
		var targets []string
		if rawFare.SubRouteID != "" {
			for _, native := range []string{rawFare.SubRouteID, prefixID(prefix, rawFare.SubRouteID)} {
				if uid := nativeToCanonical[native]; uid != "" {
					targets = append(targets, uid)
				}
			}
			if len(targets) == 0 {
				uid, _ := shared.CanonicalSubroute(city, prefixID(prefix, rawFare.SubRouteID), 0)
				if snapshot.subroutes[uid] != nil {
					targets = append(targets, uid)
				}
			}
		}
		if rawFare.IsForAllSubRoutes == 1 && rawFare.RouteID != "" {
			for uid := range routeToCanonical[prefixID(prefix, rawFare.RouteID)] {
				targets = append(targets, uid)
			}
			for uid := range routeToCanonical[rawFare.RouteID] {
				targets = append(targets, uid)
			}
		}
		if len(targets) == 0 {
			return nil, _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "RouteFare cannot map native route/subroute IDs")
		}
		for _, uid := range uniqueStrings(targets) {
			fareCandidates[uid] = append(fareCandidates[uid], fare)
		}
	}
	for _, uid := range pipeline.SortedKeys(fareCandidates) {
		sub := snapshot.subroutes[uid]
		if sub == nil {
			// The subroute lost its stop lists above; nothing left to price.
			q.Drop("routefare", "routefare_dangling", uid)
			continue
		}
		sub.Fare = mergeBusFares(fareCandidates[uid])
	}

	// Quarantining a tail keeps the city current; quarantining a third of it
	// ships a gutted city that looks fresh. Past the ratio the city fails
	// instead, keeping the previous load's rows — stale but whole.
	if err := q.Exceeded(); err != nil {
		return nil, _oops.Join(errBusSnapshotInvalid, err)
	}
	if unsurveyedStops > 0 || unsurveyedStations > 0 {
		zap.S().Warnw("unsurveyed positions",
			"component", "load",
			"action", "bus",
			"event", "unsurveyed_positions",
			"city", city,
			"stop_count", unsurveyedStops,
			"station_count", unsurveyedStations,
		)
	}
	if err := snapshot.buildWriteRows(); err != nil {
		return nil, err
	}
	return snapshot, nil
}

func readBusRawDataset(ctx context.Context, src raw.LandingCycleSource, city, table string) ([]byte, string, error) {
	body, fetchedAt, landingCycle, err := src.DatasetJSONWithLandingCycle(ctx, table, "city", city)
	if err != nil {
		return nil, "", _oops.With("table", table).With("city", city).Wrapf(err, "read raw partition")
	}
	if fetchedAt.IsZero() || raw.IsStale(fetchedAt) {
		return nil, "", _oops.With("table", table).With("city", city).With("fetched_at", fetchedAt.Format(time.RFC3339)).Wrapf(errBusSnapshotIncomplete, "landing state is missing or stale")
	}
	if strings.TrimSpace(landingCycle) == "" {
		return nil, "", _oops.With("table", table).With("city", city).Wrapf(errBusSnapshotIncomplete, "landing state has no cycle")
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return nil, "", _oops.With("table", table).With("city", city).Wrapf(errBusSnapshotInvalid, "has empty JSON body")
	}
	return body, landingCycle, nil
}
