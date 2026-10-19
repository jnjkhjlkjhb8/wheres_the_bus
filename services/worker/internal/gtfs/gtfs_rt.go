package gtfs

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

const (
	RTCadence = "@every 30s"
	// _gtfsRTSnapshotTTL outlives several rebuild periods so an ordinary slow
	// tick cannot blank the feed, while still expiring fast enough that a dead
	// builder is noticed as a 503 rather than served as fresh data.
	_gtfsRTSnapshotTTL = 3 * time.Minute
	// RTBuildTimeout bounds one rebuild. The Redis scan dominates it; the
	// static index is already in memory.
	RTBuildTimeout = 60 * time.Second
	// RTIndexTimeout bounds one load of the published index snapshot.
	RTIndexTimeout = 10 * time.Minute
	// _gtfsRTMGetBatch bounds one MGET. A few thousand subroutes is a handful of
	// round trips at this size, and no single reply is large enough to matter.
	_gtfsRTMGetBatch = 256
)

// gtfsRTRouteKey identifies one canonical subroute direction — the granularity
// at which the daily timetable is published and the gate is decided.
type gtfsRTRouteKey struct {
	subRouteUID string
	direction   int32
}

// gtfsRTTrip is one static bus trip reduced to what a cancellation needs: the
// id to name it by, the days it runs, and the origin departure that identifies
// it within its subroute direction.
type gtfsRTTrip struct {
	tripID    string
	departure int
	// week is Sunday-first, matching both time.Weekday and the EXTRACT(DOW)
	// ordering gtfsWeekArraySQL emits.
	week [7]bool
}

// gtfsRTIndex is the static half, rebuilt once a day.
type gtfsRTIndex struct {
	// runID is the published pipeline run the index was loaded from, and
	// builtFor the service date (Taipei local) its rail trains were picked for.
	// Either one changing triggers a reload.
	runID    string
	builtFor string
	trips    map[gtfsRTRouteKey][]gtfsRTTrip
	// rail is today's TRA trains by train number, for the delay producer. It
	// shares this index's lifetime because it goes stale for the same reason:
	// train numbers are reused, so yesterday's entry names yesterday's trip.
	rail map[string]railDelayTrip
	// offsets is each bus stop's running time from its route direction's origin,
	// which is what turns a live arrival back into the departure a vehicle is
	// running. It moves when bus_segment_time is recomputed, which is nightly.
	offsets map[gtfsRTRouteKey]map[string]int64
}

// gtfsRTDailyReader returns one canonical subroute's daily timetable, or nil
// when TDX published none for it today. It is the seam the Redis client sits
// behind so the diff can be tested without one.
type gtfsRTDailyReader func(ctx context.Context, subRouteUIDs []string) (map[string]*models.Bus_DailyTimetables, error)

// gtfsRTStats records why trips did not reach the feed. Silence is the designed
// behaviour, so it has to be measurable or the feed's coverage is unknowable.
type gtfsRTStats struct {
	routesConsidered int
	routesNoDaily    int
	routesGateFailed int
	tripsActive      int
	cancellations    int
}

// The index reads the snapshot `pipeline` froze for the published run
// (migrations/2026-10-08-static-release-gtfs-rt-snapshot.sql).
const (
	_publishedRunSQL = `SELECT run_id FROM static_release ORDER BY build_seq DESC LIMIT 1`

	_gtfsRTTripIndexSQL = `SELECT trip_id, direction_id, service_id FROM gtfs_rt_bus_trip WHERE run_id = $1`
)

// gtfsRTBuilder owns the static index between ticks. Only the cron entry touches
// it, and addStaticCron's non-overlap guard keeps that single-threaded.
type gtfsRTBuilder struct {
	db    *pgxpool.Pool
	rc    *redis.Client
	index *gtfsRTIndex
}

func (b *gtfsRTBuilder) Run(ctx context.Context, now time.Time) error {
	if err := b.refreshIndex(ctx, now); err != nil {
		return err
	}
	if !b.hasStaticTrips() {
		return errors.New("gtfs-rt: static trip index is empty")
	}
	entities, running, stats := buildGTFSRTCancellations(ctx, b.index, now, b.readDailyTimetables)
	// The three producers cover different modes and fail independently, so a read
	// that errors costs its own entities and nothing else's.
	entities = append(entities, b.railDelayEntities(ctx, now)...)
	entities = append(entities, b.busDelayEntities(ctx, running, now)...)
	return b.publishGTFSRTFeed(ctx, entities, stats, now)
}

func (b *gtfsRTBuilder) railDelayEntities(ctx context.Context, now time.Time) []*gtfs.FeedEntity {
	minutes, stations, err := readRailDelays(ctx, b.rc)
	if err != nil {
		zap.S().Warnw("failed", "component", "gtfs_rt", "action", "delay", "event", "failed", "err", err)
		return nil
	}
	delays, stats := buildGTFSRTRailDelays(b.index.rail, minutes, stations, now)
	logGTFSRTRailDelayStats(stats)
	return delays
}

func (b *gtfsRTBuilder) busDelayEntities(ctx context.Context, running map[gtfsRTRouteKey][]gtfsRTTrip, now time.Time) []*gtfs.FeedEntity {
	arrivals, err := b.readBusArrivals(ctx)
	if err != nil {
		zap.S().Warnw("failed", "component", "gtfs_rt", "action", "bus_delay", "event", "failed", "err", err)
		return nil
	}
	delays, stats := buildGTFSRTBusDelays(running, arrivals, b.index.offsets, now)
	logGTFSRTBusStats(stats)
	return delays
}

func (b *gtfsRTBuilder) publishGTFSRTFeed(ctx context.Context, entities []*gtfs.FeedEntity, stats gtfsRTStats, now time.Time) error {
	payload, err := marshalGTFSRTFeed(entities, now)
	if err != nil {
		return err
	}
	if err := b.rc.Set(ctx, shared.GTFSRealtimeKey(), payload, _gtfsRTSnapshotTTL).Err(); err != nil {
		return _oops.Wrapf(err, "gtfs-rt: publish snapshot")
	}
	zap.S().Infow("success",
		"component", "gtfs_rt",
		"action", "build",
		"event", "success",
		"bytes", len(payload),
		"entities", len(entities),
		"routes_considered", stats.routesConsidered,
		"routes_no_daily", stats.routesNoDaily,
		"routes_gate_failed", stats.routesGateFailed,
		"trips_active", stats.tripsActive,
	)
	return nil
}

// refreshIndex reloads the static half from the published run's snapshot when
// a new run is published or the service date moves on. It reads only what
// `pipeline run publish` has released, so the index always matches the feed
// MOTIS is serving, whenever the nightly run finishes.
func (b *gtfsRTBuilder) refreshIndex(ctx context.Context, now time.Time) error {
	today := now.Format(time.DateOnly)
	indexCtx, cancel := context.WithTimeout(ctx, RTIndexTimeout)
	defer cancel()
	var runID string
	err := b.db.QueryRow(indexCtx, _publishedRunSQL).Scan(&runID)
	if err != nil {
		return b.publishedRunFailure(err)
	}
	if b.indexCurrent(runID, today) {
		return nil
	}
	return b.reloadIndex(indexCtx, runID, today)
}

func (b *gtfsRTBuilder) publishedRunFailure(err error) error {
	if errors.Is(err, pgx.ErrNoRows) && b.index == nil {
		return errors.New("gtfs-rt: no published static run")
	}
	if b.index != nil {
		zap.S().Warnw("release check failed",
			"component", "gtfs_rt",
			"action", "index",
			"event", "release_check_failed",
			"keeping", b.index.runID,
			"err", err,
		)
		return nil
	}
	return _oops.Wrapf(err, "gtfs-rt: read published run")

}

func (b *gtfsRTBuilder) reloadIndex(ctx context.Context, runID, today string) error {
	index, err := loadGTFSRTIndex(ctx, b.db, runID, today)
	if err != nil {
		// A failed reload keeps yesterday's index rather than emptying the feed:
		// the two differ only by whatever TDX republished overnight, which is far
		// less wrong than cancelling nothing at all for a day.
		if b.index != nil {
			zap.S().Warnw("reload failed",
				"component", "gtfs_rt",
				"action", "index",
				"event", "reload_failed",
				"keeping", b.index.builtFor,
				"err", err,
			)
			return nil
		}
		return err
	}
	b.index = index
	zap.S().Infow("loaded",
		"component", "gtfs_rt",
		"action", "index",
		"event", "loaded",
		"run_id", index.runID,
		"date", index.builtFor,
		"routes", len(index.trips),
		"rail_trains", len(index.rail),
		"pattern_directions", len(index.offsets),
	)
	return nil
}

// loadGTFSRTIndex reads run runID's bus trips and groups them by the canonical
// subroute direction the daily timetable is keyed by.
func loadGTFSRTIndex(ctx context.Context, db *pgxpool.Pool, runID, today string) (*gtfsRTIndex, error) {
	rows, err := db.Query(ctx, _gtfsRTTripIndexSQL, runID)
	if err != nil {
		return nil, _oops.Wrapf(err, "gtfs-rt: load trip index")
	}
	defer rows.Close()
	index, err := readBusTripIndex(rows, runID, today)
	if err != nil {
		return nil, err
	}

	return loadGTFSRTComponents(ctx, db, index, runID, today)
}

func loadGTFSRTComponents(ctx context.Context, db *pgxpool.Pool, index *gtfsRTIndex, runID, today string) (*gtfsRTIndex, error) {
	rail, err := loadRailDelayIndex(ctx, db, runID, today)
	if err != nil {
		return nil, err
	}
	index.rail = rail
	offsets, err := loadBusPatternOffsets(ctx, db, runID)
	if err != nil {
		return nil, err
	}
	index.offsets = offsets
	return index, nil
}

func parseGTFSRTTrip(tripID, serviceID string, direction int32) (gtfsRTTrip, gtfsRTRouteKey, bool) {
	parts := strings.Split(tripID, ":")
	if len(parts) != 5 {
		return gtfsRTTrip{}, gtfsRTRouteKey{}, false
	}
	tdxUID, departure := parts[0], parts[2]
	if !validGTFSRTTripIdentity(tdxUID, departure, direction) {
		return gtfsRTTrip{}, gtfsRTRouteKey{}, false
	}
	return parseGTFSRTTripSchedule(tripID, serviceID, tdxUID, departure, direction)
}

func parseGTFSRTTripSchedule(tripID, serviceID, tdxUID, departure string, direction int32) (gtfsRTTrip, gtfsRTRouteKey, bool) {
	minutes, ok := parseGTFSRTCompactTime(departure)
	if !ok {
		return gtfsRTTrip{}, gtfsRTRouteKey{}, false
	}
	week, ok := parseGTFSRTWeekMask(serviceID)
	if !ok {
		return gtfsRTTrip{}, gtfsRTRouteKey{}, false
	}
	uid, dir := canonicalGTFSRTSubroute(tdxUID, uint8(direction))
	return gtfsRTTrip{tripID: tripID, departure: minutes, week: week},
		gtfsRTRouteKey{subRouteUID: uid, direction: int32(dir)}, true
}

func canonicalGTFSRTSubroute(tdxUID string, direction uint8) (string, uint8) {
	city := ""
	if len(tdxUID) >= 3 {
		city = busmodel.CityToCode[tdxUID[:3]]
	}
	return shared.CanonicalSubroute(city, tdxUID, direction)
}

func parseGTFSRTCompactTime(compact string) (int, bool) {
	if !compactGTFSRTShape(compact) {
		return 0, false
	}
	return parseGTFSRTCompactParts(compact[:len(compact)-2], compact[len(compact)-2:])
}

func compactGTFSRTShape(compact string) bool { return len(compact) >= 3 && len(compact) <= 4 }

func parseGTFSRTCompactParts(hourText, minuteText string) (int, bool) {
	hour, err := strconv.Atoi(hourText)
	if err != nil {
		return 0, false
	}
	minute, err := strconv.Atoi(minuteText)
	if err != nil || minute > 59 {
		return 0, false
	}
	return hour*60 + minute, true
}

// parseGTFSRTClockTime reads TDX's "H:MM"/"HH:MM" as minutes since midnight.
func parseGTFSRTClockTime(clock string) (int, bool) {
	hourText, minuteText, found := strings.Cut(strings.TrimSpace(clock), ":")
	if !found {
		return 0, false
	}
	return parseGTFSRTClockParts(hourText, minuteText)
}

func parseGTFSRTClockParts(hourText, minuteText string) (int, bool) {
	hour, ok := nonnegativeGTFSRTNumber(hourText)
	if !ok {
		return 0, false
	}
	minute, ok := gtfsRTClockMinute(minuteText)
	if !ok {
		return 0, false
	}
	return hour*60 + minute, true
}

func gtfsRTClockMinute(raw string) (int, bool) {
	minute, ok := nonnegativeGTFSRTNumber(raw)
	return minute, ok && minute <= 59
}

func nonnegativeGTFSRTNumber(raw string) (int, bool) {
	value, err := strconv.Atoi(raw)
	return value, err == nil && value >= 0
}

// parseGTFSRTWeekMask reads "W:1111100" into a Sunday-first week. The mask is
// written Monday-first (gtfsWeekMaskSQL) and read Sunday-first here because
// time.Weekday and EXTRACT(DOW) both start at Sunday.
func parseGTFSRTWeekMask(serviceID string) ([7]bool, bool) {
	var week [7]bool
	mask, found := strings.CutPrefix(serviceID, "W:")
	if !found || len(mask) != 7 {
		return week, false
	}
	return decodeGTFSRTWeekMask(mask)
}

func decodeGTFSRTWeekMask(mask string) ([7]bool, bool) {
	var week [7]bool
	for index := range mask {
		if !validGTFSRTWeekDigit(mask[index]) {
			return [7]bool{}, false
		}
		week[(index+1)%7] = mask[index] == '1'
	}
	return week, true
}

func validGTFSRTWeekDigit(digit byte) bool { return digit == '0' || digit == '1' }

func buildGTFSRTCancellations(
	ctx context.Context,
	index *gtfsRTIndex,
	now time.Time,
	read gtfsRTDailyReader,
) ([]*gtfs.FeedEntity, map[gtfsRTRouteKey][]gtfsRTTrip, gtfsRTStats) {
	var stats gtfsRTStats
	weekday := int(now.Weekday())
	serviceDate := now.Format("20060102")

	active, uids := activeGTFSRTTrips(index, weekday, &stats)

	daily, err := read(ctx, uids)
	if err != nil {
		zap.S().Errorw("read failed", "component", "gtfs_rt", "action", "daily", "event", "read_failed", "err", err)
		return nil, nil, stats
	}

	keys := gtfsRTActiveRouteKeys(active)
	entities, running := cancelledGTFSRTRoutes(keys, active, daily, serviceDate, &stats)
	return entities, running, stats
}

func cancelledGTFSRTRoutes(keys []gtfsRTRouteKey, active map[gtfsRTRouteKey][]gtfsRTTrip, daily map[string]*models.Bus_DailyTimetables, serviceDate string, stats *gtfsRTStats) ([]*gtfs.FeedEntity, map[gtfsRTRouteKey][]gtfsRTTrip) {
	entities := make([]*gtfs.FeedEntity, 0, 512)
	// Every trip that survives is a candidate the matcher may assign a vehicle
	// to; a cancelled one never reaches this map.
	running := make(map[gtfsRTRouteKey][]gtfsRTTrip, len(active))
	for _, key := range keys {
		cancelled, matched := cancellationsForRoute(key, active[key], daily[key.subRouteUID], serviceDate, stats)
		entities = append(entities, cancelled...)
		if matched != nil {
			running[key] = matched
		}
	}

	return entities, running
}

func gtfsRTActiveRouteKeys(active map[gtfsRTRouteKey][]gtfsRTTrip) []gtfsRTRouteKey {
	keys := make([]gtfsRTRouteKey, 0, len(active))
	for key := range active {
		keys = append(keys, key)
	}
	sortGTFSRTDirections(keys)
	return keys
}

// gtfsRTGatePasses reports whether every observed departure is one the schedule
// also states. One unexplained observation disqualifies the subroute.
func gtfsRTGatePasses(observed map[int]struct{}, scheduled map[int][]string) bool {
	for departure := range observed {
		if _, known := scheduled[departure]; !known {
			return false
		}
	}
	return true
}

func observedDepartures(timetable *models.Bus_DailyTimetables, direction int32) (map[int]struct{}, bool) {
	entry := timetable.GetDirection()[direction]
	if entry == nil {
		return nil, false
	}
	return observedTimetableDepartures(entry), true
}

func observedTimetableDepartures(entry *models.Bus_DirectionTimetable) map[int]struct{} {
	observed := make(map[int]struct{}, len(entry.GetDailyTimetables()))
	for _, trip := range entry.GetDailyTimetables() {
		minutes, found := observedDepartureMinutes(trip)
		if found {
			observed[minutes] = struct{}{}
		}

	}
	return observed
}

// originStopTime returns the call with the lowest stop sequence, which is the
// departure the trip_id was built from. The stored order is not relied on.
func originStopTime(trip *models.Bus_DailyTimetable) *models.Bus_StopTime {
	var origin *models.Bus_StopTime
	for _, stop := range trip.GetStopTimes() {
		if origin == nil || stop.GetStopSequence() < origin.GetStopSequence() {
			origin = stop
		}
	}
	return origin
}

// cancelledTripEntity states that one trip does not run today. No stop time
// updates: the trip is gone, not rescheduled.
func cancelledTripEntity(tripID, serviceDate string) *gtfs.FeedEntity {
	return &gtfs.FeedEntity{
		Id: proto.String(tripID),
		TripUpdate: &gtfs.TripUpdate{
			Trip: &gtfs.TripDescriptor{
				TripId:               proto.String(tripID),
				StartDate:            proto.String(serviceDate),
				ScheduleRelationship: gtfs.TripDescriptor_CANCELED.Enum(),
			},
		},
	}
}

// marshalGTFSRTFeed wraps the entities in a full-dataset header. Every rebuild
// replaces the whole feed; there is no incremental mode to get wrong.
func marshalGTFSRTFeed(entities []*gtfs.FeedEntity, now time.Time) ([]byte, error) {
	feed := &gtfs.FeedMessage{
		Header: &gtfs.FeedHeader{
			GtfsRealtimeVersion: proto.String("2.0"),
			Incrementality:      gtfs.FeedHeader_FULL_DATASET.Enum(),
			Timestamp:           proto.Uint64(uint64(now.Unix())),
		},
		Entity: entities,
	}
	payload, err := proto.Marshal(feed)
	if err != nil {
		return nil, _oops.Wrapf(err, "gtfs-rt: marshal feed")
	}
	return payload, nil
}

func (b *gtfsRTBuilder) readDailyTimetables(ctx context.Context, subRouteUIDs []string) (map[string]*models.Bus_DailyTimetables, error) {
	out := make(map[string]*models.Bus_DailyTimetables, len(subRouteUIDs))
	for start := 0; start < len(subRouteUIDs); start += _gtfsRTMGetBatch {
		end := min(start+_gtfsRTMGetBatch, len(subRouteUIDs))
		if err := b.readDailyBatch(ctx, subRouteUIDs[start:end], out); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func (b *gtfsRTBuilder) readDailyBatch(ctx context.Context, batch []string, out map[string]*models.Bus_DailyTimetables) error {
	keys := make([]string, len(batch))
	for i, uid := range batch {
		keys[i] = shared.BusDailyTimetableKey(uid)
	}
	values, err := b.rc.MGet(ctx, keys...).Result()
	if err != nil {
		return _oops.Wrapf(err, "gtfs-rt: read daily timetables")
	}
	decodeDailyBatch(values, batch, out)
	return nil
}

func decodeDailyBatch(values []any, batch []string, out map[string]*models.Bus_DailyTimetables) {
	for i, value := range values {
		if timetable := decodeDailyTimetable(value, batch[i]); timetable != nil {
			out[batch[i]] = timetable
		}
	}
}

func decodeDailyTimetable(value any, uid string) *models.Bus_DailyTimetables {
	text, ok := value.(string)
	if !ok || text == "" {
		return nil
	}
	timetable := &models.Bus_DailyTimetables{}
	if err := proto.Unmarshal([]byte(text), timetable); err != nil {
		// Dropping one corrupt snapshot silences only that route.
		zap.S().Warnw("decode failed", "component", "gtfs_rt", "action", "daily", "event", "decode_failed", "subroute", uid, "err", err)
		return nil
	}
	return timetable
}

// NewRTBuilder builds the GTFS-Realtime snapshot builder. It owns the static
// trip index between ticks, so the caller must keep one instance and never run
// two ticks concurrently.
func NewRTBuilder(db *pgxpool.Pool, rc *redis.Client) *gtfsRTBuilder {
	return &gtfsRTBuilder{db: db, rc: rc}
}

func activeGTFSRTTrips(index *gtfsRTIndex, weekday int, stats *gtfsRTStats) (map[gtfsRTRouteKey][]gtfsRTTrip, []string) {
	active := make(map[gtfsRTRouteKey][]gtfsRTTrip, len(index.trips))
	uidSet := make(map[string]struct{}, len(index.trips))
	for key, trips := range index.trips {
		running := weekdayGTFSRTTrips(trips, weekday)
		if len(running) == 0 {
			continue
		}
		active[key] = running
		uidSet[key.subRouteUID] = struct{}{}
		stats.routesConsidered++
		stats.tripsActive += len(running)
	}
	uids := make([]string, 0, len(uidSet))
	for uid := range uidSet {
		uids = append(uids, uid)
	}
	sort.Strings(uids)

	return active, uids
}

func weekdayGTFSRTTrips(trips []gtfsRTTrip, weekday int) []gtfsRTTrip {
	running := make([]gtfsRTTrip, 0, len(trips))
	for _, trip := range trips {
		if trip.week[weekday] {
			running = append(running, trip)
		}
	}
	return running
}

func cancellationsForRoute(key gtfsRTRouteKey, trips []gtfsRTTrip, daily *models.Bus_DailyTimetables, serviceDate string, stats *gtfsRTStats) ([]*gtfs.FeedEntity, []gtfsRTTrip) {
	var running []gtfsRTTrip
	observed, ok := observedDepartures(daily, key.direction)
	if !ok {
		stats.routesNoDaily++
		return nil, trips
	}
	scheduled := make(map[int][]string, len(trips))
	for _, trip := range trips {
		scheduled[trip.departure] = append(scheduled[trip.departure], trip.tripID)
	}
	if !gtfsRTGatePasses(observed, scheduled) {
		// The two sources disagree about how this subroute names a departure,
		// so no cancellation can be proven — but neither is any trip proven
		// gone, so they all stay matchable.
		stats.routesGateFailed++
		return nil, trips
	}
	running = observedRunningTrips(trips, observed)
	entities := cancelledDepartures(observed, scheduled, serviceDate, stats)

	return entities, running
}

func observedRunningTrips(trips []gtfsRTTrip, observed map[int]struct{}) []gtfsRTTrip {
	var running []gtfsRTTrip
	for _, trip := range trips {
		if _, ran := observed[trip.departure]; ran {
			running = append(running, trip)
		}
	}
	return running
}

func cancelledDepartures(observed map[int]struct{}, scheduled map[int][]string, serviceDate string, stats *gtfsRTStats) []*gtfs.FeedEntity {
	entities := make([]*gtfs.FeedEntity, 0)
	departures := make([]int, 0, len(scheduled))
	for departure := range scheduled {
		departures = append(departures, departure)
	}
	sort.Ints(departures)
	for _, departure := range departures {
		if _, ran := observed[departure]; ran {
			continue
		}
		entities = append(entities, cancelledDepartureEntities(scheduled[departure], serviceDate, stats)...)
	}
	return entities
}

func cancelledDepartureEntities(tripIDs []string, serviceDate string, stats *gtfsRTStats) []*gtfs.FeedEntity {
	var entities []*gtfs.FeedEntity
	for _, tripID := range tripIDs {
		entities = append(entities, cancelledTripEntity(tripID, serviceDate))
		stats.cancellations++
	}
	return entities
}

func (b *gtfsRTBuilder) indexCurrent(runID, today string) bool {
	return b.index != nil && b.index.runID == runID && b.index.builtFor == today
}

func (b *gtfsRTBuilder) hasStaticTrips() bool {
	return b.index != nil && len(b.index.trips) != 0
}

func validGTFSRTTripIdentity(uid, departure string, direction int32) bool {
	return uid != "" && departure != "" && direction >= 0 && direction <= 1
}

func readBusTripIndex(rows pgx.Rows, runID, today string) (*gtfsRTIndex, error) {
	index := &gtfsRTIndex{runID: runID, builtFor: today, trips: make(map[gtfsRTRouteKey][]gtfsRTTrip, 8192)}
	if err := indexBusTripRows(rows, index); err != nil {
		return nil, err
	}
	if err := rows.Err(); err != nil {
		return nil, _oops.Wrapf(err, "gtfs-rt: load trip index: rows")
	}
	return index, nil
}

func indexBusTripRows(rows pgx.Rows, index *gtfsRTIndex) error {
	for rows.Next() {
		if err := indexBusTripRow(rows, index); err != nil {
			return err
		}
	}
	return nil
}

func indexBusTripRow(rows pgx.Rows, index *gtfsRTIndex) error {
	var tripID, serviceID string
	var direction int32
	if err := rows.Scan(&tripID, &direction, &serviceID); err != nil {
		return _oops.Wrapf(err, "gtfs-rt: load trip index: scan")
	}
	trip, key, ok := parseGTFSRTTrip(tripID, serviceID, direction)
	if ok {
		index.trips[key] = append(index.trips[key], trip)
	}
	return nil
}

func observedDepartureMinutes(trip *models.Bus_DailyTimetable) (int, bool) {
	origin := originStopTime(trip)
	if origin == nil {
		return 0, false
	}
	clock := preferredDepartureClock(origin)
	minutes, parsed := parseGTFSRTClockTime(clock)
	if !parsed {
		// An unreadable departure must fail the cancellation gate rather than disappear from it.
		return -1, true
	}
	return minutes, true

}

func preferredDepartureClock(origin *models.Bus_StopTime) string {
	clock := origin.GetDepartureTime()
	if strings.TrimSpace(clock) == "" {
		clock = origin.GetArrivalTime()
	}
	return clock
}

func checkedGTFSRTRows(rows pgx.Rows, description string) error {
	if err := rows.Err(); err != nil {
		return _oops.Wrapf(err, "%s", description)
	}
	return nil
}
