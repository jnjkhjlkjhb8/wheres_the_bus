package gtfs

import (
	"context"
	"sort"
	"time"

	"github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

const (
	_gtfsRTBusMatchWindow = 20 * time.Minute
	_gtfsRTBusMinCalls    = 2
	// _gtfsRTScanBatch is the COUNT hint for the live-snapshot scan. It matches
	// the one the live jobs' own key sweep uses; the whole keyspace here is a few
	// thousand keys, so this is a handful of round trips.
	_gtfsRTScanBatch = 500
)

const _busPatternOffsetSQL = `
SELECT sub_route_uid, direction, stop_uid, offset_secs FROM gtfs_rt_bus_offset WHERE run_id = $1`

func (b *gtfsRTBuilder) readBusArrivals(ctx context.Context) (map[string]*models.Bus_RouteArrival, error) {
	keys, err := scanBusArrivalKeys(ctx, b.rc)
	if err != nil {
		return nil, err
	}

	return b.readBusArrivalBatches(ctx, keys)
}

func (b *gtfsRTBuilder) readBusArrivalBatches(ctx context.Context, keys []string) (map[string]*models.Bus_RouteArrival, error) {
	arrivals := make(map[string]*models.Bus_RouteArrival, len(keys))
	for start := 0; start < len(keys); start += _gtfsRTMGetBatch {
		end := min(start+_gtfsRTMGetBatch, len(keys))
		values, err := b.rc.MGet(ctx, keys[start:end]...).Result()
		if err != nil {
			return nil, _oops.Wrapf(err, "gtfs-rt: read bus arrivals")
		}
		decodeBusArrivals(values, arrivals)
	}
	return arrivals, nil
}

// gtfsRTBusStats records why a running vehicle produced no trip update. Every
// counter is a gate, and their ratios are the only measure of how much of the
// live feed this producer can actually speak for.
type gtfsRTBusStats struct {
	vehiclesSeen    int
	plateAmbiguous  int
	patternUnknown  int
	tooFewCalls     int
	routeNoTrips    int
	unmatched       int
	matched         int
	stopTimeUpdates int
}

// gtfsRTVehicle is one plate observed on one subroute direction, reduced to the
// two things matching needs: where it must have started, and what it is
// predicted to do next.
type gtfsRTVehicle struct {
	plate     string
	projected int64
	calls     []gtfsRTCall
}

// gtfsRTCall is one live arrival estimate.
type gtfsRTCall struct {
	stopUID  string
	sequence int32
	arrival  int64
}

// loadBusPatternOffsets reads the offsets for every complete route direction. It
// is refreshed with the rest of the static index rather than per tick: it
// changes when bus_segment_time is recomputed, which is nightly.
func loadBusPatternOffsets(ctx context.Context, db *pgxpool.Pool, runID string) (map[gtfsRTRouteKey]map[string]int64, error) {
	rows, err := db.Query(ctx, _busPatternOffsetSQL, runID)
	if err != nil {
		return nil, _oops.Wrapf(err, "gtfs-rt: load bus pattern offsets")
	}
	defer rows.Close()
	return readBusPatternOffsets(rows)
}

func readBusPatternOffsets(rows pgx.Rows) (map[gtfsRTRouteKey]map[string]int64, error) {
	offsets := make(map[gtfsRTRouteKey]map[string]int64, 8192)
	if err := indexBusPatternOffsetRows(rows, offsets); err != nil {
		return nil, err
	}
	if err := checkedGTFSRTRows(rows, "gtfs-rt: load bus pattern offsets: rows"); err != nil {
		return nil, err
	}
	return offsets, nil
}

func indexBusPatternOffsetRows(rows pgx.Rows, offsets map[gtfsRTRouteKey]map[string]int64) error {
	for rows.Next() {
		if err := indexBusPatternOffset(rows, offsets); err != nil {
			return err
		}
	}
	return nil
}

func indexBusPatternOffset(rows pgx.Rows, offsets map[gtfsRTRouteKey]map[string]int64) error {
	var subRouteUID, stopUID string
	var direction int32
	var offset int64
	if err := rows.Scan(&subRouteUID, &direction, &stopUID, &offset); err != nil {
		return _oops.Wrapf(err, "gtfs-rt: load bus pattern offsets: scan")
	}
	key := gtfsRTRouteKey{subRouteUID: subRouteUID, direction: direction}
	if offsets[key] == nil {
		offsets[key] = make(map[string]int64, 32)
	}
	offsets[key][stopUID] = offset
	return nil
}

func platesOnOneSubroute(arrivals map[string]*models.Bus_RouteArrival) map[string]bool {
	seen := make(map[string]map[string]bool, 4096)
	for uid, arrival := range arrivals {
		recordArrivalPlates(uid, arrival, seen)
	}
	unique := make(map[string]bool, len(seen))
	for plate, uids := range seen {
		unique[plate] = len(uids) == 1
	}
	return unique
}

func recordArrivalPlates(uid string, arrival *models.Bus_RouteArrival, seen map[string]map[string]bool) {
	for _, stop := range arrival.GetStops() {
		recordPlateSubroute(stop.GetPlateNumb(), uid, seen)
	}
}

func recordPlateSubroute(plate, uid string, seen map[string]map[string]bool) {
	if plate == "" {
		return
	}
	if seen[plate] == nil {
		seen[plate] = make(map[string]bool, 2)
	}
	seen[plate][uid] = true
}

// collectBusVehicles groups one subroute's estimates into vehicles and
// back-projects each one's origin departure.
func collectBusVehicles(
	arrival *models.Bus_RouteArrival,
	offsets map[gtfsRTRouteKey]map[string]int64,
	onOneSubroute map[string]bool,
	stats *gtfsRTBusStats,
) map[gtfsRTRouteKey][]gtfsRTVehicle {
	calls, projections := collectBusCalls(arrival, offsets)

	vehicles := make(map[gtfsRTRouteKey][]gtfsRTVehicle, 4)
	for id, seen := range calls {
		projected := projections[id]
		if !usableBusVehicle(id, projected, onOneSubroute, stats) {
			continue
		}
		sort.Slice(seen, func(i, j int) bool { return seen[i].sequence < seen[j].sequence })
		vehicles[id.key] = append(vehicles[id.key], gtfsRTVehicle{
			plate:     id.plate,
			projected: medianUnix(projected),
			calls:     seen,
		})
	}
	return vehicles
}

func usableBusVehicle(id gtfsRTVehicleKey, projected []int64, onOneSubroute map[string]bool, stats *gtfsRTBusStats) bool {
	stats.vehiclesSeen++
	if !onOneSubroute[id.plate] {
		stats.plateAmbiguous++
		return false
	}
	return usableBusProjection(projected, stats)
}

func usableBusProjection(projected []int64, stats *gtfsRTBusStats) bool {
	if len(projected) == 0 {
		stats.patternUnknown++
		return false
	}
	if len(projected) < _gtfsRTBusMinCalls {
		stats.tooFewCalls++
		return false
	}
	return true
}

func medianUnix(values []int64) int64 {
	sorted := make([]int64, len(values))
	copy(sorted, values)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	return sorted[(len(sorted)-1)/2]
}

func matchBusVehicles(vehicles []gtfsRTVehicle, trips []gtfsRTTrip, midnight time.Time) map[string]gtfsRTVehicle {
	sort.Slice(vehicles, func(i, j int) bool { return vehicles[i].projected < vehicles[j].projected })
	scheduled := make([]gtfsRTTrip, len(trips))
	copy(scheduled, trips)
	sort.Slice(scheduled, func(i, j int) bool { return scheduled[i].departure < scheduled[j].departure })

	state := busVehicleMatcher{vehicles: vehicles, scheduled: scheduled, midnight: midnight, window: int64(_gtfsRTBusMatchWindow / time.Second), matched: make(map[string]gtfsRTVehicle, len(vehicles))}
	for state.vehicleIndex < len(vehicles) && state.tripIndex < len(scheduled) {
		state.advance()
	}
	return state.matched
}

type busVehicleMatcher struct {
	vehicles                []gtfsRTVehicle
	scheduled               []gtfsRTTrip
	midnight                time.Time
	window                  int64
	vehicleIndex, tripIndex int
	matched                 map[string]gtfsRTVehicle
}

func (s *busVehicleMatcher) advance() {
	planned := s.midnight.Unix() + int64(s.scheduled[s.tripIndex].departure)*60
	gap := s.vehicles[s.vehicleIndex].projected - planned
	if gap < -s.window {
		s.vehicleIndex++
		return
	}
	if gap > s.window {
		s.tripIndex++
		return
	}
	s.matchCurrentVehicle(gap)
}

func (s *busVehicleMatcher) matchCurrentVehicle(gap int64) {
	// The next departure can fit better when this vehicle is running late.
	if nextBusDepartureCloser(s.vehicles[s.vehicleIndex].projected, gap, s.scheduled, s.tripIndex, s.midnight) {
		s.tripIndex++
		return
	}
	s.matched[s.scheduled[s.tripIndex].tripID] = s.vehicles[s.vehicleIndex]
	s.vehicleIndex++
	s.tripIndex++
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

func buildGTFSRTBusDelays(
	running map[gtfsRTRouteKey][]gtfsRTTrip,
	arrivals map[string]*models.Bus_RouteArrival,
	offsets map[gtfsRTRouteKey]map[string]int64,
	now time.Time,
) ([]*gtfs.FeedEntity, gtfsRTBusStats) {
	var stats gtfsRTBusStats
	onOneSubroute := platesOnOneSubroute(arrivals)
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	serviceDate := now.Format("20060102")

	byKey := busVehiclesByRoute(arrivals, offsets, onOneSubroute, &stats)
	keys := make([]gtfsRTRouteKey, 0, len(byKey))
	for key := range byKey {
		keys = append(keys, key)
	}
	sortGTFSRTDirections(keys)

	entities := make([]*gtfs.FeedEntity, 0, 512)
	for _, key := range keys {
		entities = append(entities, routeBusDelayEntities(key, byKey[key], running[key], midnight, serviceDate, &stats)...)
	}
	sort.Slice(entities, func(i, j int) bool { return entities[i].GetId() < entities[j].GetId() })
	return entities, stats
}

func busVehiclesByRoute(arrivals map[string]*models.Bus_RouteArrival, offsets map[gtfsRTRouteKey]map[string]int64, onOneSubroute map[string]bool, stats *gtfsRTBusStats) map[gtfsRTRouteKey][]gtfsRTVehicle {
	byKey := make(map[gtfsRTRouteKey][]gtfsRTVehicle, len(arrivals))
	for _, arrival := range arrivals {
		for key, vehicles := range collectBusVehicles(arrival, offsets, onOneSubroute, stats) {
			byKey[key] = append(byKey[key], vehicles...)
		}
	}
	return byKey
}

func routeBusDelayEntities(key gtfsRTRouteKey, vehicles []gtfsRTVehicle, scheduled []gtfsRTTrip, midnight time.Time, serviceDate string, stats *gtfsRTBusStats) []*gtfs.FeedEntity {
	var entities []*gtfs.FeedEntity
	trips := scheduled
	if len(trips) == 0 {
		stats.routeNoTrips += len(vehicles)
		return nil
	}
	matched := matchBusVehicles(vehicles, trips, midnight)
	stats.unmatched += len(vehicles) - len(matched)
	for tripID, vehicle := range matched {
		stats.matched++
		updates := busStopTimeUpdates(vehicle)
		stats.stopTimeUpdates += len(updates)
		entities = append(entities, &gtfs.FeedEntity{
			Id: proto.String(tripID),
			TripUpdate: &gtfs.TripUpdate{
				Trip: &gtfs.TripDescriptor{
					TripId:               proto.String(tripID),
					StartDate:            proto.String(serviceDate),
					ScheduleRelationship: gtfs.TripDescriptor_SCHEDULED.Enum(),
				},
				Vehicle:        &gtfs.VehicleDescriptor{Id: proto.String(vehicle.plate)},
				StopTimeUpdate: updates,
			},
		})
	}
	return entities
}

func busStopTimeUpdates(vehicle gtfsRTVehicle) []*gtfs.TripUpdate_StopTimeUpdate {
	updates := make([]*gtfs.TripUpdate_StopTimeUpdate, 0, len(vehicle.calls))
	var previous int64
	for _, call := range vehicle.calls {
		arrival := call.arrival
		if arrival < previous {
			arrival = previous
		}
		previous = arrival
		updates = append(updates, &gtfs.TripUpdate_StopTimeUpdate{
			StopId:  proto.String(call.stopUID),
			Arrival: &gtfs.TripUpdate_StopTimeEvent{Time: proto.Int64(arrival)},
		})
	}
	return updates
}

// logGTFSRTBusStats reports the matcher's coverage. Every counter but the last
// two is a vehicle the live feed knows about and the published feed says nothing
// for, which is the number that says whether the gates are set right.
func logGTFSRTBusStats(stats gtfsRTBusStats) {
	zap.S().Infow("built",
		"component", "gtfs_rt",
		"action", "bus_delay",
		"event", "built",
		"vehicles_seen", stats.vehiclesSeen,
		"plate_ambiguous", stats.plateAmbiguous,
		"pattern_unknown", stats.patternUnknown,
		"too_few_calls", stats.tooFewCalls,
		"route_no_trips", stats.routeNoTrips,
		"unmatched", stats.unmatched,
		"matched", stats.matched,
		"stop_time_updates", stats.stopTimeUpdates,
	)
}

func scanBusArrivalKeys(ctx context.Context, rc *redis.Client) ([]string, error) {
	var keys []string
	var cursor uint64
	for {
		batch, next, err := rc.Scan(ctx, cursor, shared.BusRouteEtaPattern(""), _gtfsRTScanBatch).Result()
		if err != nil {
			return nil, _oops.Wrapf(err, "gtfs-rt: scan bus arrivals")
		}
		keys = append(keys, batch...)
		cursor = next
		if cursor == 0 {
			break
		}
	}
	return keys, nil
}

func decodeBusArrivals(values []any, arrivals map[string]*models.Bus_RouteArrival) {
	for _, value := range values {
		if arrival := decodeBusArrival(value); arrival != nil {
			arrivals[arrival.GetSubRouteUid()] = arrival
		}
	}
}

func decodeBusArrival(value any) *models.Bus_RouteArrival {
	raw, ok := gtfsRTSnapshotText(value)
	if !ok {
		return nil
	}
	return decodeBusArrivalText(raw)
}

func gtfsRTSnapshotText(value any) (string, bool) {
	raw, ok := value.(string)
	return raw, ok && raw != ""
}

func decodeBusArrivalText(raw string) *models.Bus_RouteArrival {
	arrival := &models.Bus_RouteArrival{}
	if err := proto.Unmarshal([]byte(raw), arrival); err != nil {
		// One undecodable snapshot costs its own subroute, not the tick.
		return nil
	}
	if arrival.GetSubRouteUid() == "" {
		return nil
	}
	return arrival
}

type gtfsRTVehicleKey struct {
	key   gtfsRTRouteKey
	plate string
}

func collectBusCalls(arrival *models.Bus_RouteArrival, offsets map[gtfsRTRouteKey]map[string]int64) (map[gtfsRTVehicleKey][]gtfsRTCall, map[gtfsRTVehicleKey][]int64) {

	calls := make(map[gtfsRTVehicleKey][]gtfsRTCall, 64)
	projections := make(map[gtfsRTVehicleKey][]int64, 64)
	for _, stop := range arrival.GetStops() {
		appendBusCall(arrival.GetSubRouteUid(), stop, offsets, calls, projections)
	}

	return calls, projections
}

func appendBusCall(uid string, stop *models.Bus_RouteEstimate, offsets map[gtfsRTRouteKey]map[string]int64, calls map[gtfsRTVehicleKey][]gtfsRTCall, projections map[gtfsRTVehicleKey][]int64) {
	plate := stop.GetPlateNumb()
	if !usableBusCall(stop) {
		return
	}
	key := gtfsRTRouteKey{subRouteUID: uid, direction: stop.GetDirection()}
	id := gtfsRTVehicleKey{key: key, plate: plate}
	calls[id] = append(calls[id], gtfsRTCall{
		stopUID:  stop.GetStopUid(),
		sequence: stop.GetStopSequence(),
		arrival:  stop.GetArrivalUnix(),
	})
	if offset, known := offsets[key][stop.GetStopUid()]; known {
		projections[id] = append(projections[id], stop.GetArrivalUnix()-offset)
	}
}

func usableBusCall(stop *models.Bus_RouteEstimate) bool {
	return stop.GetPlateNumb() != "" && stop.GetArrivalUnix() > 0 && stop.GetStopUid() != ""
}

func nextBusDepartureCloser(projected, gap int64, scheduled []gtfsRTTrip, index int, midnight time.Time) bool {
	if index+1 >= len(scheduled) {
		return false
	}
	next := midnight.Unix() + int64(scheduled[index+1].departure)*60
	return abs64(projected-next) < abs64(gap)
}

func sortGTFSRTDirections(keys []gtfsRTRouteKey) {
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].subRouteUID != keys[j].subRouteUID {
			return keys[i].subRouteUID < keys[j].subRouteUID
		}
		return keys[i].direction < keys[j].direction
	})
}
