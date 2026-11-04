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
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
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

type busSnapshotBuilder struct {
	ctx                                 context.Context
	source                              raw.LandingCycleSource
	snapshot                            *busCitySnapshot
	quarantine                          *pipeline.Quarantine
	operators                           map[string]busmodel.RawOperator
	routeToCanonical                    map[string]map[string]struct{}
	nativeToCanonical                   map[string]string
	stations                            []rawBusStation
	unsurveyedStops, unsurveyedStations int
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
	return readBusSnapshotDatasets(ctx, cycleSource, city, prefix)
}

func readBusSnapshotDatasets(ctx context.Context, cycleSource raw.LandingCycleSource, city, prefix string) (*busCitySnapshot, error) {
	b := &busSnapshotBuilder{ctx: ctx, source: cycleSource,
		snapshot:   &busCitySnapshot{city: city, prefix: prefix, subroutes: make(map[string]*models.BusSubroute)},
		quarantine: pipeline.NewQuarantine("bus", city)}
	defer b.quarantine.Report()
	for _, read := range []func() error{b.readOperators, b.readRoutes, b.readStops, b.readShapes, b.readSchedules, b.readStations, b.readGroups, b.readFares} {
		if err := read(); err != nil {
			return nil, err
		}
	}
	return b.finish()
}

func (b *busSnapshotBuilder) readDataset(table string) ([]byte, error) {
	body, cycle, err := readBusRawDataset(b.ctx, b.source, b.snapshot.city, table)
	if err != nil {
		return nil, err
	}
	if b.snapshot.landingCycle == "" {
		b.snapshot.landingCycle = cycle
	} else if cycle != b.snapshot.landingCycle {
		return nil, _oops.With("table", table).With("city", b.snapshot.city).With("cycle", cycle).With("landing_cycle", b.snapshot.landingCycle).Wrapf(errBusSnapshotIncomplete, "landing cycle does not match")
	}
	return body, nil
}

func (b *busSnapshotBuilder) readOperators() error {
	var operators []busmodel.RawOperator
	if err := b.decodeDataset("bus_operator", "Operator", &operators); err != nil {
		return err
	}
	return b.indexOperators(operators)
}

func (b *busSnapshotBuilder) indexOperators(operators []busmodel.RawOperator) error {
	opByID := make(map[string]busmodel.RawOperator, len(operators))
	for i, op := range operators {
		if err := b.addOperator(i, op, opByID); err != nil {
			return err
		}
	}
	b.operators = opByID
	return nil
}
func (b *busSnapshotBuilder) addOperator(i int, op busmodel.RawOperator, opByID map[string]busmodel.RawOperator) error {
	if err := validateBusOperatorIdentity(i, op); err != nil {
		return err
	}
	return b.indexOperator(i, op, opByID)
}

func validateBusOperatorIdentity(i int, op busmodel.RawOperator) error {
	hasID := strings.TrimSpace(op.OperatorID) != ""
	hasName := strings.TrimSpace(op.OperatorName.Zhtw) != ""
	hasAuthority := strings.TrimSpace(op.AuthorityCode) != ""
	if !hasID || !hasName || !hasAuthority {
		return _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "Operator has incomplete identity")
	}
	return nil
}

func (b *busSnapshotBuilder) indexOperator(i int, op busmodel.RawOperator, opByID map[string]busmodel.RawOperator) error {
	if op.AuthorityCode != b.snapshot.prefix {
		return _oops.With("index", i).With("authority_code", op.AuthorityCode).With("city", b.snapshot.city).Wrapf(errBusSnapshotInvalid, "Operator authority does not belong")
	}
	if old, ok := opByID[op.OperatorID]; ok && !jsonSemanticEqual(old, op) {
		return _oops.With("operator_id", op.OperatorID).Wrapf(errBusSnapshotConflict, "OperatorID has divergent variants")
	}
	opByID[op.OperatorID] = op
	return nil
}
func (b *busSnapshotBuilder) readRoutes() error {
	var routes []busmodel.RawRoute
	if err := b.decodeDataset("bus_route", "Route", &routes); err != nil {
		return err
	}
	return b.indexRoutes(routes)
}

func (b *busSnapshotBuilder) indexRoutes(routes []busmodel.RawRoute) error {
	b.setOperatorRows()
	b.routeToCanonical = make(map[string]map[string]struct{})
	b.nativeToCanonical = make(map[string]string)
	b.quarantine.Consider("subroute", countBusSubroutes(routes))
	for ri, route := range routes {
		if err := b.addRoute(ri, route); err != nil {
			return err
		}
	}
	return b.finishRoutes()
}
func (b *busSnapshotBuilder) setOperatorRows() {
	for _, operatorID := range pipeline.SortedKeys(b.operators) {
		op := b.operators[operatorID]
		b.snapshot.operatorRows = append(b.snapshot.operatorRows, []any{op.OperatorID, op.AuthorityCode, op.OperatorName.Zhtw, sanitizeOperatorPhone(op.OperatorPhone), op.OperatorURL})
	}
}
func (b *busSnapshotBuilder) finishRoutes() error {
	if len(b.snapshot.subroutes) == 0 {
		return _oops.Wrapf(errBusSnapshotInvalid, "Route produced zero canonical subroutes")
	}
	for _, sub := range b.snapshot.subroutes {
		sort.Slice(sub.Operators, func(i, j int) bool { return sub.Operators[i].OperatorId < sub.Operators[j].OperatorId })
		applySubrouteEndpoints(sub)
	}
	return nil
}
func (b *busSnapshotBuilder) addRoute(ri int, route busmodel.RawRoute) error {
	if err := b.validateRoute(ri, route); err != nil {
		return err
	}
	ops, err := b.routeOperators(route)
	if err != nil {
		return err
	}
	return b.addRouteSubroutes(ri, route, ops)
}

func (b *busSnapshotBuilder) addRouteSubroutes(ri int, route busmodel.RawRoute, ops []*models.BusOperator) error {
	for si := range route.SubRoutes {
		if err := b.addSubroute(ri, si, route, ops); err != nil {
			return err
		}
	}
	return nil
}
func (b *busSnapshotBuilder) validateRoute(ri int, route busmodel.RawRoute) error {
	hasUID := strings.TrimSpace(route.RouteUID) != ""
	hasName := strings.TrimSpace(route.RouteName.Zhtw) != ""
	if !hasBusRouteIdentity(hasUID, hasName, len(route.SubRoutes)) {
		return _oops.With("route_index", ri).Wrapf(errBusSnapshotInvalid, "Route missing route identity or subroutes")
	}
	if !uidBelongsToPrefix(route.RouteUID, b.snapshot.prefix) {
		return _oops.With("route_index", ri).With("route_uid", route.RouteUID).With("city", b.snapshot.city).Wrapf(errBusSnapshotInvalid, "Route UID does not belong")
	}
	return nil
}
func (b *busSnapshotBuilder) routeOperators(route busmodel.RawRoute) ([]*models.BusOperator, error) {
	var ops []*models.BusOperator
	for _, ref := range route.Operators {
		op, ok := b.operators[ref.OperatorID]
		if !ok {
			return nil, _oops.With("route_uid", route.RouteUID).With("operator_id", ref.OperatorID).Wrapf(errBusSnapshotInvalid, "Route references unknown operator")
		}
		ops = appendUniqueOperator(ops, &models.BusOperator{
			OperatorId: ref.OperatorID, OperatorName: op.OperatorName.Zhtw,
			OperatorPhone: sanitizeOperatorPhone(op.OperatorPhone), OperatorUrl: op.OperatorURL,
		})
	}
	return ops, nil
}
func (b *busSnapshotBuilder) addSubroute(ri, si int, route busmodel.RawRoute, ops []*models.BusOperator) error {
	sub := route.SubRoutes[si]
	uid, dir := shared.CanonicalSubroute(b.snapshot.city, sub.SubRouteUID, sub.Direction)
	if !validBusSubrouteIdentity(uid, sub.SubRouteUID, sub.SubRouteName.Zhtw, dir) {
		// Unusable identity: nothing downstream can key off this
		// subroute, so it goes rather than the city.
		b.quarantine.Drop("subroute", "subroute_identity", fmt.Sprintf("Route[%d].SubRoutes[%d] uid=%q dir=%d", ri, si, sub.SubRouteUID, sub.Direction))
		return nil
	}
	return b.addOwnedSubroute(ri, si, uid, dir, route, ops)
}

func (b *busSnapshotBuilder) addOwnedSubroute(ri, si int, uid string, dir uint8, route busmodel.RawRoute, ops []*models.BusOperator) error {
	sub := route.SubRoutes[si]
	if err := b.validateSubrouteOwnership(ri, si, uid, sub.SubRouteUID); err != nil {
		return err
	}
	fields := []busClockField{
		{label: "FirstBusTime", value: &sub.FirstBusTime}, {label: "LastBusTime", value: &sub.LastBusTime},
		{label: "HolidayFirstBusTime", value: &sub.HolidayFirstBusTime}, {label: "HolidayLastBusTime", value: &sub.HolidayLastBusTime},
	}
	normalizeSubrouteClocks(uid, dir, b.quarantine, fields)
	dep, dest := busDirectionEndpoints(sub.DepartureStopNameZh, sub.DestinationStopNameZh, route.DepartureStopNameZh, route.DestinationStopNameZh, dir)
	candidate := &models.Direction{
		DepartureStopName: dep, DestinationStopName: dest,
		FirstBusTime: sub.FirstBusTime, LastBusTime: sub.LastBusTime,
		HolidayFirstBusTime: sub.HolidayFirstBusTime, HolidayLastBusTime: sub.HolidayLastBusTime,
	}

	if err := b.mergeSubroute(uid, dir, route, si, ops, candidate); err != nil {
		return err
	}
	b.indexRouteCanonical(route.RouteUID, uid)

	return b.mapNativeSubroute(uid, sub.SubRouteUID, sub.SubRouteID)
}

func validBusSubrouteIdentity(uid, nativeUID, name string, dir uint8) bool {
	return strings.TrimSpace(uid) != "" && strings.TrimSpace(nativeUID) != "" && strings.TrimSpace(name) != "" && dir <= 1
}

type busClockField struct {
	label string
	value *string
}

func normalizeSubrouteClocks(uid string, dir uint8, q *pipeline.Quarantine, fields []busClockField) {
	for _, f := range fields {
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
}
func busDirectionEndpoints(departure, destination, routeDeparture, routeDestination string, dir uint8) (string, string) {
	dep, dest := departure, destination
	if dep == "" {
		dep = routeDeparture
	}
	if dest == "" {
		dest = routeDestination
	}
	if dir == 1 {
		dep, dest = dest, dep
	}
	return dep, dest
}
func (b *busSnapshotBuilder) mergeSubroute(uid string, dir uint8, route busmodel.RawRoute, si int, ops []*models.BusOperator, candidate *models.Direction) error {
	sub := route.SubRoutes[si]
	dep, dest := candidate.DepartureStopName, candidate.DestinationStopName
	existing := b.snapshot.subroutes[uid]
	if existing == nil {
		existing = &models.BusSubroute{
			RouteUID: route.RouteUID, RouteName: route.RouteName.Zhtw,
			SubRouteUID: uid, SubRouteName: sub.SubRouteName.Zhtw, City: b.snapshot.city,
			DepartureStopName: dep, DestinationStopName: dest,
			Directions: make(map[int32]*models.Direction), Operators: ops,
		}
		b.snapshot.subroutes[uid] = existing
	} else {
		if err := validateBusSubrouteVariant(uid, existing, route, si); err != nil {
			return err
		}
		mergeBusOperators(existing, ops)
	}
	return mergeBusDirection(uid, dir, existing, candidate)
}

func mergeBusDirection(uid string, dir uint8, existing *models.BusSubroute, candidate *models.Direction) error {
	if prior := existing.Directions[int32(dir)]; prior != nil {
		if !proto.Equal(prior, candidate) {
			return _oops.With("uid", uid).With("dir", dir).Wrapf(errBusSnapshotConflict, "canonical route direction has divergent route variants")
		}
		return nil
	}
	existing.Directions[int32(dir)] = candidate
	return nil
}
func validateBusSubrouteVariant(uid string, existing *models.BusSubroute, route busmodel.RawRoute, si int) error {
	sub := route.SubRoutes[si]
	sameRouteUID := existing.RouteUID == route.RouteUID
	sameRouteName := existing.RouteName == route.RouteName.Zhtw
	sameSubName := existing.SubRouteName == sub.SubRouteName.Zhtw
	if !sameRouteUID || !sameRouteName || !sameSubName {
		return _oops.With("uid", uid).Wrapf(errBusSnapshotConflict, "canonical route has divergent route/name variants")
	}
	return nil
}
func (b *busSnapshotBuilder) mapNativeSubroute(uid, nativeUID, nativeID string) error {
	for _, native := range []string{nativeUID, nativeID, prefixID(b.snapshot.prefix, nativeID)} {
		if err := b.indexNativeSubroute(uid, native); err != nil {
			return err
		}
	}
	return nil
}

func (b *busSnapshotBuilder) readStops() error {
	var stopVariants []busmodel.RawStopOfRoute
	if err := b.decodeDataset("bus_stopofroute", "StopOfRoute", &stopVariants); err != nil {
		return err
	}
	return b.indexStopVariants(stopVariants)
}

func (b *busSnapshotBuilder) indexStopVariants(stopVariants []busmodel.RawStopOfRoute) error {
	b.quarantine.Consider("stopofroute", len(stopVariants))
	seen := make(map[string]busmodel.RawStopOfRoute)
	for i, variant := range stopVariants {
		if err := b.addStopVariant(i, variant, seen); err != nil {
			return err
		}
	}
	return b.finishStopVariants()
}

func (b *busSnapshotBuilder) finishStopVariants() error {
	for _, uid := range pipeline.SortedKeys(b.snapshot.subroutes) {
		b.pruneEmptyBusDirections(uid)
	}
	if len(b.snapshot.subroutes) == 0 {
		return _oops.Wrapf(errBusSnapshotInvalid, "every canonical subroute lost its StopOfRoute")
	}
	return nil
}
func (b *busSnapshotBuilder) addStopVariant(i int, variant busmodel.RawStopOfRoute, seen map[string]busmodel.RawStopOfRoute) error {
	uid, dir := shared.CanonicalSubroute(b.snapshot.city, variant.SubRouteUID, variant.Direction)
	route := b.snapshot.subroutes[uid]
	direction := directionFor(b.snapshot.subroutes, uid, dir)
	if err := b.validateStopVariantOwner(i, variant); err != nil {
		return err
	}
	if !hasBusStopVariantParent(uid, b.snapshot.prefix, route, direction) {
		// Dangling reference: the parent subroute was never published, or
		// was itself dropped above. Nothing to attach these stops to.
		b.quarantine.Drop("stopofroute", "stopofroute_dangling", fmt.Sprintf("StopOfRoute[%d] -> %s/%d", i, uid, dir))
		return nil
	}
	return b.addParentStopVariant(i, uid, dir, route, direction, variant, seen)
}

func (b *busSnapshotBuilder) addParentStopVariant(i int, uid string, dir uint8, route *models.BusSubroute, direction *models.Direction, variant busmodel.RawStopOfRoute, seen map[string]busmodel.RawStopOfRoute) error {
	if err := validateStopVariantParent(i, uid, route.RouteUID, variant); err != nil {
		return err
	}
	return b.addValidatedStopVariant(i, uid, dir, direction, variant, seen)
}

func (b *busSnapshotBuilder) addValidatedStopVariant(i int, uid string, dir uint8, direction *models.Direction, variant busmodel.RawStopOfRoute, seen map[string]busmodel.RawStopOfRoute) error {
	valid, err := b.validateStopSequence(i, uid, dir, variant)
	if err != nil {
		return err
	}
	if !valid {
		return nil
	}
	b.attachStopVariant(uid, dir, direction, variant, seen)
	return nil
}
func hasBusStopVariantParent(uid, prefix string, route *models.BusSubroute, direction *models.Direction) bool {
	return uidBelongsToPrefix(uid, prefix) && route != nil && direction != nil
}

func validateStopVariantParent(i int, uid, parentUID string, variant busmodel.RawStopOfRoute) error {
	if variant.RouteUID != parentUID {
		return _oops.With("index", i).With("route_uid", variant.RouteUID).With("route_uid_2", parentUID).With("uid", uid).Wrapf(errBusSnapshotInvalid, "StopOfRoute parent does not match")
	}
	if len(variant.Stops) == 0 {
		return _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "StopOfRoute has no stops")
	}
	return nil
}
func (b *busSnapshotBuilder) validateStopVariantOwner(i int, variant busmodel.RawStopOfRoute) error {
	if !uidBelongsToPrefix(variant.RouteUID, b.snapshot.prefix) || !uidBelongsToPrefix(variant.SubRouteUID, b.snapshot.prefix) {
		return _oops.With("index", i).With("sub_route_uid", variant.SubRouteUID).With("city", b.snapshot.city).Wrapf(errBusSnapshotInvalid, "StopOfRoute UID does not belong")
	}
	return nil
}
func (b *busSnapshotBuilder) validateStopSequence(i int, uid string, dir uint8, variant busmodel.RawStopOfRoute) (bool, error) {
	lastSequence := uint8(0)
	for j, stop := range variant.Stops {
		if err := b.validateSequenceStop(i, j, variant); err != nil {
			return false, err
		}
		if stop.StopSequence <= lastSequence {
			b.quarantine.Drop("stopofroute", "stopofroute_unordered", fmt.Sprintf("StopOfRoute[%d] %s/%d seq=%d", i, uid, dir, stop.StopSequence))
			return false, nil
		}
		lastSequence = stop.StopSequence
	}
	return true, nil
}
func (b *busSnapshotBuilder) attachStopVariant(uid string, dir uint8, direction *models.Direction, variant busmodel.RawStopOfRoute, seenStops map[string]busmodel.RawStopOfRoute) {
	snapshot, q := b.snapshot, b.quarantine
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
		return
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
func (b *busSnapshotBuilder) pruneEmptyBusDirections(uid string) {
	sub := b.snapshot.subroutes[uid]
	pruned := false
	for _, dir := range []int32{0, 1} {
		if b.pruneBusDirection(uid, dir, sub) {
			pruned = true
		}
	}
	b.finishPrunedBusDirections(uid, sub, pruned)
}

func (b *busSnapshotBuilder) finishPrunedBusDirections(uid string, sub *models.BusSubroute, pruned bool) {
	if !pruned {
		return
	}
	if len(sub.Directions) == 0 {
		delete(b.snapshot.subroutes, uid)
		return
	}
	// The surviving direction now owns the subroute-level endpoints.
	applySubrouteEndpoints(sub)
}

func (b *busSnapshotBuilder) readShapes() error {
	var shapes []busmodel.RawShape
	if err := b.decodeDataset("bus_shape", "Shape", &shapes); err != nil {
		return err
	}
	return b.indexShapes(shapes)
}

func (b *busSnapshotBuilder) indexShapes(shapes []busmodel.RawShape) error {
	b.quarantine.Consider("shape", len(shapes))
	seen := make(map[string]string)
	for i, shape := range shapes {
		if err := b.addShape(i, shape, seen); err != nil {
			return err
		}
	}
	return nil
}
func (b *busSnapshotBuilder) addShape(i int, shape busmodel.RawShape, seen map[string]string) error {
	q := b.quarantine
	targets, err := b.shapeTargets(i, shape)
	if err != nil {
		return err
	}
	if len(targets) == 0 {
		// A shape whose RouteUID is absent from bus_route entirely.
		// Geometry is the map polyline only, so the route stays fully
		// usable without it.
		q.Drop("shape", "shape_unknown_route", fmt.Sprintf("Shape[%d]->route:%s", i, shape.RouteUID))
		return nil
	}
	return b.attachShapeTargets(i, shape, seen, targets)
}

func (b *busSnapshotBuilder) attachShapeTargets(i int, shape busmodel.RawShape, seen map[string]string, targets []string) error {
	for _, uid := range targets {
		if err := b.attachShape(i, uid, shape, seen); err != nil {
			return err
		}
	}
	return nil
}
func (b *busSnapshotBuilder) shapeTargets(i int, shape busmodel.RawShape) ([]string, error) {
	if strings.TrimSpace(shape.Geometry) == "" {
		return nil, _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "Shape has empty Geometry")
	}
	if shape.SubRouteUID != "" {
		return b.subrouteShapeTargets(i, shape)
	}
	return b.routeShapeTargets(i, shape)
}
func (b *busSnapshotBuilder) subrouteShapeTargets(i int, shape busmodel.RawShape) ([]string, error) {
	city, prefix := b.snapshot.city, b.snapshot.prefix
	uid, _ := shared.CanonicalSubroute(city, shape.SubRouteUID, shape.Direction)
	if !allBusShapeOwnersMatch(uidBelongsToPrefix(shape.RouteUID, prefix), uidBelongsToPrefix(shape.SubRouteUID, prefix), uidBelongsToPrefix(uid, prefix)) {
		return nil, _oops.With("index", i).With("city", city).Wrapf(errBusSnapshotInvalid, "Shape subroute UID does not belong")
	}
	return []string{uid}, nil
}
func (b *busSnapshotBuilder) routeShapeTargets(i int, shape busmodel.RawShape) ([]string, error) {
	if !uidBelongsToPrefix(shape.RouteUID, b.snapshot.prefix) {
		return nil, _oops.With("index", i).With("city", b.snapshot.city).Wrapf(errBusSnapshotInvalid, "Shape route UID does not belong")
	}
	var targets []string
	for uid := range b.routeToCanonical[shape.RouteUID] {
		targets = append(targets, uid)
	}
	return targets, nil
}
func allBusShapeOwnersMatch(route, nativeSub, canonicalSub bool) bool {
	return route && nativeSub && canonicalSub
}

func (b *busSnapshotBuilder) attachShape(i int, uid string, shape busmodel.RawShape, seenShapes map[string]string) error {
	city, snapshot := b.snapshot.city, b.snapshot
	_, dir := shared.CanonicalSubroute(city, shape.SubRouteUID, shape.Direction)
	route := snapshot.subroutes[uid]
	direction := directionFor(snapshot.subroutes, uid, dir)
	if !hasBusShapeParent(route, direction) {
		b.dropUnknownShape(i, uid, dir, shape)
		return nil
	}
	// A parent mismatch is a payload-integrity signal, not a per-record
	// defect: it stays fatal alongside the foreign-UID checks.
	if !busShapeParentMatches(shape.RouteUID, route.RouteUID) {
		return _oops.With("index", i).With("route_uid", shape.RouteUID).With("route_uid_2", route.RouteUID).With("uid", uid).Wrapf(errBusSnapshotInvalid, "Shape parent does not match")
	}
	return b.bindShape(uid, dir, direction, shape, seenShapes)
}

func (b *busSnapshotBuilder) bindShape(uid string, dir uint8, direction *models.Direction, shape busmodel.RawShape, seenShapes map[string]string) error {
	q := b.quarantine
	key := fmt.Sprintf("%s/%d", uid, dir)
	if prior, ok := seenShapes[key]; ok && prior != shape.Geometry {
		// First variant wins, as for StopOfRoute above.
		q.Drop("shape", "shape_divergent", key)
		return nil
	}
	seenShapes[key] = shape.Geometry
	direction.Geometry = shape.Geometry
	return nil
}

func busShapeParentMatches(shapeParent, routeParent string) bool {
	return shapeParent == "" || shapeParent == routeParent
}

func (b *busSnapshotBuilder) readSchedules() error {
	var schedules []busmodel.RawSchedule
	if err := b.decodeDataset("bus_schedule", "Schedule", &schedules); err != nil {
		return err
	}
	return b.indexSchedules(schedules)
}

func (b *busSnapshotBuilder) indexSchedules(schedules []busmodel.RawSchedule) error {
	b.quarantine.Consider("schedule", len(schedules))
	seen := make(map[string]busmodel.RawSchedule)
	for i, schedule := range schedules {
		if err := b.addSchedule(i, schedule, seen); err != nil {
			return err
		}
	}
	return nil
}
func (b *busSnapshotBuilder) addSchedule(i int, schedule busmodel.RawSchedule, seen map[string]busmodel.RawSchedule) error {
	city, prefix := b.snapshot.city, b.snapshot.prefix
	snapshot, q := b.snapshot, b.quarantine
	uid, dir := shared.CanonicalSubroute(city, schedule.SubRouteUID, schedule.Direction)
	route := snapshot.subroutes[uid]
	direction := directionFor(snapshot.subroutes, uid, dir)
	if err := b.validateScheduleOwner(i, schedule); err != nil {
		return err
	}
	if !hasBusStopVariantParent(uid, prefix, route, direction) {
		q.Drop("schedule", "schedule_dangling", fmt.Sprintf("Schedule[%d] -> %s/%d", i, uid, dir))
		return nil
	}
	return b.addParentSchedule(i, uid, dir, route, direction, schedule, seen)
}

func (b *busSnapshotBuilder) addParentSchedule(i int, uid string, dir uint8, route *models.BusSubroute, direction *models.Direction, schedule busmodel.RawSchedule, seen map[string]busmodel.RawSchedule) error {
	// A parent mismatch is a payload-integrity signal, not a per-record
	// defect: it stays fatal alongside the foreign-UID checks.
	if schedule.RouteUID != route.RouteUID {
		return _oops.With("index", i).With("route_uid", schedule.RouteUID).With("route_uid_2", route.RouteUID).With("uid", uid).Wrapf(errBusSnapshotInvalid, "Schedule parent does not match")
	}
	b.attachSchedule(i, uid, dir, direction, schedule, seen)
	return nil
}
func (b *busSnapshotBuilder) attachSchedule(i int, uid string, dir uint8, direction *models.Direction, schedule busmodel.RawSchedule, seenSchedules map[string]busmodel.RawSchedule) {
	snapshot, q := b.snapshot, b.quarantine
	key := fmt.Sprintf("%s/%d", uid, dir)
	if prior, ok := seenSchedules[key]; ok {
		// First variant wins, as for StopOfRoute and Shape above.
		if !jsonSemanticEqual(prior, schedule) {
			q.Drop("schedule", "schedule_divergent", key)
		}
		return
	}
	seenSchedules[key] = schedule
	rows, modelRows, err := buildScheduleRows(uid, dir, schedule)
	if err != nil {
		// One malformed timetable (an empty TripID, an unparseable stop
		// time) costs this subroute its schedule, not the city its load.
		q.Drop("schedule", "schedule_malformed", fmt.Sprintf("Schedule[%d] %s/%d: %v", i, uid, dir, err))
		return
	}
	snapshot.scheduleRows = append(snapshot.scheduleRows, rows...)
	direction.Schedules = append(direction.Schedules, modelRows...)
}

type busStationIndex struct {
	uids  map[string]struct{}
	ids   map[string]string
	byUID map[string]rawBusStation
}

func (b *busSnapshotBuilder) readStations() error {
	var stations []rawBusStation
	if err := b.decodeDataset("bus_station", "Station", &stations); err != nil {
		return err
	}
	return b.indexStations(stations)
}

func (b *busSnapshotBuilder) indexStations(stations []rawBusStation) error {
	index := busStationIndex{uids: make(map[string]struct{}, len(stations)), ids: make(map[string]string, len(stations)), byUID: make(map[string]rawBusStation, len(stations))}
	for i, station := range stations {
		if err := b.addStation(i, station, index); err != nil {
			return err
		}
	}
	return b.finishStations(index)
}

func (b *busSnapshotBuilder) finishStations(index busStationIndex) error {
	for _, uid := range pipeline.SortedKeys(index.byUID) {
		b.stations = append(b.stations, index.byUID[uid])
	}
	return b.validateSnapshotStations(index)
}

func (b *busSnapshotBuilder) validateSnapshotStations(index busStationIndex) error {
	for uid, sub := range b.snapshot.subroutes {
		if err := b.validateRouteStations(uid, sub, index); err != nil {
			return err
		}
	}
	return nil
}
func (b *busSnapshotBuilder) addStation(i int, station rawBusStation, index busStationIndex) error {
	prefix := b.snapshot.prefix
	if err := validateBusStationIdentity(i, prefix, station); err != nil {
		return err
	}
	b.countUnsurveyedStation(station)
	return b.indexStation(station, index)
}

func (b *busSnapshotBuilder) countUnsurveyedStation(station rawBusStation) {
	// Same pending-survey case as the stop positions above. A station cannot
	// be dropped over it: every route stop referencing it would then fail the
	// missing-station check below and take the city with it.
	if !pipeline.ValidPosition(station.StationPosition.PositionLon, station.StationPosition.PositionLat) {
		b.unsurveyedStations++
	}
}

func (b *busSnapshotBuilder) indexStation(station rawBusStation, index busStationIndex) error {
	if prior, exists := index.byUID[station.StationUID]; exists {
		if !jsonSemanticEqual(prior, station) {
			return _oops.With("station_uid", station.StationUID).Wrapf(errBusSnapshotConflict, "StationUID has divergent variants")
		}
		return nil
	}
	return b.indexNewStation(station, index)
}

func (b *busSnapshotBuilder) indexNewStation(station rawBusStation, index busStationIndex) error {
	snapshot := b.snapshot
	if priorUID := index.ids[station.StationID]; priorUID != "" && priorUID != station.StationUID {
		return _oops.With("station_id", station.StationID).With("prior_uid", priorUID).With("station_uid", station.StationUID).Wrapf(errBusSnapshotConflict, "StationID maps to both")
	}
	index.byUID[station.StationUID] = station
	index.uids[station.StationUID] = struct{}{}
	index.ids[station.StationID] = station.StationUID
	snapshot.stationRows = append(snapshot.stationRows, []any{
		station.StationUID, station.StationID, normalizeStationName(station.StationName.Zhtw),
		station.StationPosition.PositionLon, station.StationPosition.PositionLat, station.StationGroupID,
	})
	return nil
}
func validateBusStationIdentity(i int, prefix string, station rawBusStation) error {
	ownUID := uidBelongsToPrefix(station.StationUID, prefix)
	if !ownUID || station.StationID == "" || station.StationName.Zhtw == "" {
		return _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "Station has invalid identity")
	}
	return nil
}
func (b *busSnapshotBuilder) validateRouteStations(uid string, sub *models.BusSubroute, index busStationIndex) error {
	for _, direction := range sub.Directions {
		if err := b.validateDirectionStations(uid, direction, index); err != nil {
			return err
		}
	}
	return nil
}
func (b *busSnapshotBuilder) validateDirectionStations(uid string, direction *models.Direction, index busStationIndex) error {
	for _, stop := range direction.Stops {
		if err := b.validateStopStation(uid, stop, index); err != nil {
			return err
		}
	}
	return nil
}
func (b *busSnapshotBuilder) validateStopStation(uid string, stop *models.BusStop, index busStationIndex) error {
	if _, ok := index.uids[prefixID(b.snapshot.prefix, stop.StationID)]; ok {
		return nil
	}
	if _, ok := index.ids[stop.StationID]; ok {
		return nil
	}
	return _oops.With("uid", uid).With("stop_uid", stop.StopUID).With("station_id", stop.StationID).Wrapf(errBusSnapshotInvalid, "route stop references missing station")
}

type manualGroupAggregate struct {
	id, source string
	name       string
	lonSum     float64
	latSum     float64
	stationCnt int
}

func (b *busSnapshotBuilder) readGroups() error {
	var groups []rawBusStationGroup
	if err := b.decodeDataset("bus_stationgroup", "StationGroup", &groups); err != nil {
		return err
	}
	return b.indexGroups(groups)
}

func (b *busSnapshotBuilder) indexGroups(groups []rawBusStationGroup) error {
	byID, byUID := make(map[string]rawBusStationGroup), make(map[string]rawBusStationGroup)
	for i, group := range groups {
		if err := b.addGroup(i, group, byID, byUID); err != nil {
			return err
		}
	}
	b.addStationGroupMembers(byID)
	return nil
}
func (b *busSnapshotBuilder) addGroup(i int, group rawBusStationGroup, groupsByID, groupsByUID map[string]rawBusStationGroup) error {
	if err := validateBusGroupIdentity(i, b.snapshot.prefix, group); err != nil {
		return err
	}
	if err := validateBusGroupID(group, groupsByID); err != nil {
		return err
	}
	return b.indexGroup(group, groupsByID, groupsByUID)
}

func validateBusGroupID(group rawBusStationGroup, groupsByID map[string]rawBusStationGroup) error {
	if prior, ok := groupsByID[group.StationGroupID]; ok && !jsonSemanticEqual(prior, group) {
		return _oops.With("station_group_id", group.StationGroupID).Wrapf(errBusSnapshotConflict, "StationGroupID has divergent UID/payload")
	}
	return nil
}

func (b *busSnapshotBuilder) indexGroup(group rawBusStationGroup, groupsByID, groupsByUID map[string]rawBusStationGroup) error {
	snapshot := b.snapshot
	if prior, ok := groupsByUID[group.StationGroupUID]; ok {
		if !jsonSemanticEqual(prior, group) {
			return _oops.With("station_group_uid", group.StationGroupUID).Wrapf(errBusSnapshotConflict, "StationGroupUID has divergent variants")
		}
		return nil
	}
	groupsByID[group.StationGroupID] = group
	groupsByUID[group.StationGroupUID] = group
	snapshot.groupRows = append(snapshot.groupRows, []any{
		group.StationGroupUID, group.StationGroupID, normalizeStationName(group.StationGroupName.Zhtw),
		group.StationGroupPosition.PositionLon, group.StationGroupPosition.PositionLat, "tdx",
	})
	return nil
}
func validateBusGroupIdentity(i int, prefix string, group rawBusStationGroup) error {
	ownUID := uidBelongsToPrefix(group.StationGroupUID, prefix)
	hasPosition := pipeline.ValidPosition(group.StationGroupPosition.PositionLon, group.StationGroupPosition.PositionLat)
	if !hasBusGroupIdentity(ownUID, group) || !hasPosition {
		return _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "StationGroup has invalid identity/position")
	}
	return nil
}
func (b *busSnapshotBuilder) addStationGroupMembers(groupsByID map[string]rawBusStationGroup) {
	snapshot, uniqueStations := b.snapshot, b.stations
	manualGroups := make(map[string]*manualGroupAggregate)
	for _, station := range uniqueStations {
		stationName := normalizeStationName(station.StationName.Zhtw)
		groupUID := b.stationGroupUID(station, stationName, groupsByID, manualGroups)
		snapshot.memberRows = append(snapshot.memberRows, []any{
			station.StationUID, groupUID, station.StationID, stationName,
			station.StationPosition.PositionLon, station.StationPosition.PositionLat,
		})
	}
	for _, uid := range pipeline.SortedKeys(manualGroups) {
		aggregate := manualGroups[uid]
		snapshot.groupRows = append(snapshot.groupRows, []any{
			uid, aggregate.id, aggregate.name,
			aggregate.lonSum / float64(aggregate.stationCnt),
			aggregate.latSum / float64(aggregate.stationCnt),
			aggregate.source,
		})
	}

}

func (b *busSnapshotBuilder) readFares() error {
	var fares []busmodel.RawFare
	if err := b.decodeDataset("bus_routefare", "RouteFare", &fares); err != nil {
		return err
	}
	return b.indexFares(fares)
}

func (b *busSnapshotBuilder) indexFares(fares []busmodel.RawFare) error {
	b.quarantine.Consider("routefare", len(fares))
	candidates := make(map[string][]*models.Bus_Fare)
	for i, fare := range fares {
		if err := b.addFareCandidates(i, fare, candidates); err != nil {
			return err
		}
	}
	b.applyFareCandidates(candidates)
	return nil
}
func (b *busSnapshotBuilder) addFareCandidates(i int, rawFare busmodel.RawFare, candidates map[string][]*models.Bus_Fare) error {
	fare := &models.Bus_Fare{
		FarePricingType: rawFare.FarePricingType, IsFreeBus: rawFare.IsFreeBus == 1,
		SectionFaresJson: jsonOrNil(rawFare.SectionFares), StageFaresJson: jsonOrNil(rawFare.StageFares), OdFaresJson: jsonOrNil(rawFare.ODFares),
	}
	targets := append(b.nativeFareTargets(rawFare), b.routeFareTargets(rawFare)...)
	if len(targets) == 0 {
		return _oops.With("index", i).Wrapf(errBusSnapshotInvalid, "RouteFare cannot map native route/subroute IDs")
	}
	for _, uid := range uniqueStrings(targets) {
		candidates[uid] = append(candidates[uid], fare)
	}
	return nil
}
func (b *busSnapshotBuilder) nativeFareTargets(rawFare busmodel.RawFare) []string {
	if rawFare.SubRouteID == "" {
		return nil
	}
	targets := b.mappedNativeFareTargets(rawFare.SubRouteID)
	if len(targets) != 0 {
		return targets
	}
	return b.canonicalFareTarget(rawFare.SubRouteID)
}
func (b *busSnapshotBuilder) mappedNativeFareTargets(nativeID string) []string {
	var targets []string
	for _, native := range []string{nativeID, prefixID(b.snapshot.prefix, nativeID)} {
		if uid := b.nativeToCanonical[native]; uid != "" {
			targets = append(targets, uid)
		}
	}
	return targets
}
func (b *busSnapshotBuilder) canonicalFareTarget(nativeID string) []string {
	uid, _ := shared.CanonicalSubroute(b.snapshot.city, prefixID(b.snapshot.prefix, nativeID), 0)
	if b.snapshot.subroutes[uid] != nil {
		return []string{uid}
	}
	return nil
}
func (b *busSnapshotBuilder) routeFareTargets(rawFare busmodel.RawFare) []string {
	if rawFare.IsForAllSubRoutes != 1 || rawFare.RouteID == "" {
		return nil
	}
	return b.targetsForFareRoute(rawFare.RouteID)
}
func (b *busSnapshotBuilder) targetsForFareRoute(routeID string) []string {
	var targets []string
	for uid := range b.routeToCanonical[prefixID(b.snapshot.prefix, routeID)] {
		targets = append(targets, uid)
	}
	for uid := range b.routeToCanonical[routeID] {
		targets = append(targets, uid)
	}
	return targets
}
func (b *busSnapshotBuilder) applyFareCandidates(fareCandidates map[string][]*models.Bus_Fare) {
	snapshot, q := b.snapshot, b.quarantine
	for _, uid := range pipeline.SortedKeys(fareCandidates) {
		sub := snapshot.subroutes[uid]
		if sub == nil {
			// The subroute lost its stop lists above; nothing left to price.
			q.Drop("routefare", "routefare_dangling", uid)
			continue
		}
		sub.Fare = mergeBusFares(fareCandidates[uid])
	}

}
func (b *busSnapshotBuilder) finish() (*busCitySnapshot, error) {
	snapshot, q := b.snapshot, b.quarantine
	// Quarantining a tail keeps the city current; quarantining a third of it
	// ships a gutted city that looks fresh. Past the ratio the city fails
	// instead, keeping the previous load's rows — stale but whole.
	if err := q.Exceeded(); err != nil {
		return nil, _oops.Join(errBusSnapshotInvalid, err)
	}
	b.reportUnsurveyedPositions()
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
	if err := validateBusRawDataset(city, table, body, fetchedAt, landingCycle); err != nil {
		return nil, "", err
	}
	return body, landingCycle, nil
}

func (b *busSnapshotBuilder) decodeDataset(table, label string, target any) error {
	body, err := b.readDataset(table)
	if err != nil {
		return err
	}
	if err := decodeStrictJSONArray(body, target); err != nil {
		return _oops.Wrapf(err, "%s", label)
	}
	return nil
}

func countBusSubroutes(routes []busmodel.RawRoute) int {
	count := 0
	for _, route := range routes {
		count += len(route.SubRoutes)
	}
	return count
}

func hasBusRouteIdentity(uid, name bool, subroutes int) bool { return uid && name && subroutes != 0 }

func (b *busSnapshotBuilder) indexRouteCanonical(routeUID, uid string) {
	if b.routeToCanonical[routeUID] == nil {
		b.routeToCanonical[routeUID] = make(map[string]struct{})
	}
	b.routeToCanonical[routeUID][uid] = struct{}{}

}

func mergeBusOperators(existing *models.BusSubroute, ops []*models.BusOperator) {
	for _, op := range ops {
		existing.Operators = appendUniqueOperator(existing.Operators, op)
	}
}

func (b *busSnapshotBuilder) indexNativeSubroute(uid, native string) error {
	if native != "" {
		if mapped := b.nativeToCanonical[native]; nativeSubrouteConflicts(mapped, uid) {
			return _oops.With("native", native).With("mapped", mapped).With("uid", uid).Wrapf(errBusSnapshotConflict, "native subroute maps to both")
		}
		b.nativeToCanonical[native] = uid
	}
	return nil
}

func (b *busSnapshotBuilder) validateSequenceStop(i, j int, variant busmodel.RawStopOfRoute) error {
	stop := variant.Stops[j]
	hasStopUID := strings.TrimSpace(stop.StopUID) != ""
	hasStopName := strings.TrimSpace(stop.StopName.Zhtw) != ""
	hasStationID := strings.TrimSpace(stop.StationID) != ""
	if !hasBusStopIdentity(hasStopUID, hasStopName, hasStationID, stop.StopSequence) {
		return _oops.With("index", i).With("index_2", j).Wrapf(errBusSnapshotInvalid, "StopOfRoute.Stops has invalid identity/sequence")
	}
	if !pipeline.ValidPosition(stop.StopPosition.PositionLon, stop.StopPosition.PositionLat) {
		b.unsurveyedStops++
	}
	return nil
}

func hasBusStopIdentity(uid, name, station bool, sequence uint8) bool {
	return uid && name && station && sequence != 0
}

func (b *busSnapshotBuilder) pruneBusDirection(uid string, dir int32, sub *models.BusSubroute) bool {
	direction := sub.Directions[dir]
	if direction == nil {
		return false
	}
	if len(direction.Stops) != 0 {
		return false
	}
	b.quarantine.Drop("stopofroute", "stopofroute_missing", fmt.Sprintf("%s/%d", uid, dir))
	delete(sub.Directions, dir)
	return true
}

func hasBusShapeParent(route *models.BusSubroute, direction *models.Direction) bool {
	return route != nil && direction != nil
}
func (b *busSnapshotBuilder) dropUnknownShape(i int, uid string, dir uint8, shape busmodel.RawShape) {
	scope := "sub"
	if shape.SubRouteUID == "" {
		scope = "routelevel"
	}
	b.quarantine.Drop("shape", "shape_unknown_direction", fmt.Sprintf("Shape[%d]/%s->%s/%d", i, scope, uid, dir))
}

func (b *busSnapshotBuilder) validateScheduleOwner(i int, schedule busmodel.RawSchedule) error {
	city, prefix := b.snapshot.city, b.snapshot.prefix
	if !uidBelongsToPrefix(schedule.RouteUID, prefix) || !uidBelongsToPrefix(schedule.SubRouteUID, prefix) {
		return _oops.With("index", i).With("sub_route_uid", schedule.SubRouteUID).With("city", city).Wrapf(errBusSnapshotInvalid, "Schedule UID does not belong")
	}
	return nil
}

func hasBusGroupIdentity(ownUID bool, group rawBusStationGroup) bool {
	return ownUID && group.StationGroupID != "" && group.StationGroupName.Zhtw != ""
}

func (b *busSnapshotBuilder) stationGroupUID(station rawBusStation, stationName string, groupsByID map[string]rawBusStationGroup, manualGroups map[string]*manualGroupAggregate) string {
	if group, ok := groupsByID[station.StationGroupID]; ok {
		return group.StationGroupUID
	}
	groupUID, groupID, source := b.derivedStationGroup(station, stationName)
	aggregate := manualGroups[groupUID]
	if aggregate == nil {
		aggregate = &manualGroupAggregate{id: groupID, source: source, name: stationName}
		manualGroups[groupUID] = aggregate
	}
	aggregate.lonSum += station.StationPosition.PositionLon
	aggregate.latSum += station.StationPosition.PositionLat
	aggregate.stationCnt++
	return groupUID
}

// derivedStationGroup names a group TDX did not send. For a city TDX serves no
// StationGroup for, it rebuilds TDX's own UID (city prefix + StationGroupID),
// because a saved bus-stop favorite holds that UID.
func (b *busSnapshotBuilder) derivedStationGroup(station rawBusStation, stationName string) (uid, id, source string) {
	if station.StationGroupID != "" && dataset.BusUnserved("bus_stationgroup", b.snapshot.city) {
		return b.snapshot.prefix + station.StationGroupID, station.StationGroupID, "station_group_id"
	}
	uid = manualGroupUID(b.snapshot.city, stationName)
	return uid, uid, "manual_name"
}

func (b *busSnapshotBuilder) reportUnsurveyedPositions() {
	city := b.snapshot.city
	unsurveyedStops, unsurveyedStations := b.unsurveyedStops, b.unsurveyedStations
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
}

func validateBusRawDataset(city, table string, body []byte, fetchedAt time.Time, landingCycle string) error {
	if fetchedAt.IsZero() || raw.IsStale(fetchedAt) {
		return _oops.With("table", table).With("city", city).With("fetched_at", fetchedAt.Format(time.RFC3339)).Wrapf(errBusSnapshotIncomplete, "landing state is missing or stale")
	}
	return validateBusRawBody(city, table, body, landingCycle)
}

func validateBusRawBody(city, table string, body []byte, landingCycle string) error {
	if strings.TrimSpace(landingCycle) == "" {
		return _oops.With("table", table).With("city", city).Wrapf(errBusSnapshotIncomplete, "landing state has no cycle")
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return _oops.With("table", table).With("city", city).Wrapf(errBusSnapshotInvalid, "has empty JSON body")
	}
	return nil
}

func nativeSubrouteConflicts(mapped, uid string) bool { return mapped != "" && mapped != uid }

func (b *busSnapshotBuilder) validateSubrouteOwnership(ri, si int, uid, nativeUID string) error {
	if !uidBelongsToPrefix(nativeUID, b.snapshot.prefix) || !uidBelongsToPrefix(uid, b.snapshot.prefix) {
		return _oops.With("route_index", ri).With("subroute_index", si).With("sub_route_uid", nativeUID).With("uid", uid).With("city", b.snapshot.city).Wrapf(errBusSnapshotInvalid, "Route.SubRoutes UID canonical does not belong")
	}
	return nil
}
