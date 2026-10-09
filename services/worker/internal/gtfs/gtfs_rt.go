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
	if b.index == nil || len(b.index.trips) == 0 {
		return errors.New("gtfs-rt: static trip index is empty")
	}
	entities, running, stats := buildGTFSRTCancellations(ctx, b.index, now, b.readDailyTimetables)
	// The three producers cover different modes and fail independently, so a read
	// that errors costs its own entities and nothing else's.
	minutes, stations, err := readRailDelays(ctx, b.rc)
	if err != nil {
		zap.S().Warnw("failed", "component", "gtfs_rt", "action", "delay", "event", "failed", "err", err)
	} else {
		delays, delayStats := buildGTFSRTRailDelays(b.index.rail, minutes, stations, now)
		logGTFSRTRailDelayStats(delayStats)
		entities = append(entities, delays...)
	}
	arrivals, err := b.readBusArrivals(ctx)
	if err != nil {
		zap.S().Warnw("failed", "component", "gtfs_rt", "action", "bus_delay", "event", "failed", "err", err)
	} else {
		busDelays, busStats := buildGTFSRTBusDelays(running, arrivals, b.index.offsets, now)
		logGTFSRTBusStats(busStats)
		entities = append(entities, busDelays...)
	}
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
	if errors.Is(err, pgx.ErrNoRows) && b.index == nil {
		return errors.New("gtfs-rt: no published static run")
	}
	if err != nil && b.index != nil {
		zap.S().Warnw("release check failed",
			"component", "gtfs_rt",
			"action", "index",
			"event", "release_check_failed",
			"keeping", b.index.runID,
			"err", err,
		)
		return nil
	}
	if err != nil {
		return _oops.Wrapf(err, "gtfs-rt: read published run")
	}
	if b.index != nil && b.index.runID == runID && b.index.builtFor == today {
		return nil
	}
	index, err := loadGTFSRTIndex(indexCtx, b.db, runID, today)
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
	index := &gtfsRTIndex{runID: runID, builtFor: today, trips: make(map[gtfsRTRouteKey][]gtfsRTTrip, 8192)}
	for rows.Next() {
		var tripID, serviceID string
		var direction int32
		if err := rows.Scan(&tripID, &direction, &serviceID); err != nil {
			return nil, _oops.Wrapf(err, "gtfs-rt: load trip index: scan")
		}
		trip, key, ok := parseGTFSRTTrip(tripID, serviceID, direction)
		if !ok {
			continue
		}
		index.trips[key] = append(index.trips[key], trip)
	}
	if err := rows.Err(); err != nil {
		return nil, _oops.Wrapf(err, "gtfs-rt: load trip index: rows")
	}
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
	if tdxUID == "" || departure == "" {
		return gtfsRTTrip{}, gtfsRTRouteKey{}, false
	}
	if direction < 0 || direction > 1 {
		return gtfsRTTrip{}, gtfsRTRouteKey{}, false
	}
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
	if len(compact) < 3 || len(compact) > 4 {
		return 0, false
	}
	hour, err := strconv.Atoi(compact[:len(compact)-2])
	if err != nil {
		return 0, false
	}
	minute, err := strconv.Atoi(compact[len(compact)-2:])
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
	hour, err := strconv.Atoi(hourText)
	if err != nil || hour < 0 {
		return 0, false
	}
	minute, err := strconv.Atoi(minuteText)
	if err != nil || minute < 0 || minute > 59 {
		return 0, false
	}
	return hour*60 + minute, true
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
	for index := range mask {
		switch mask[index] {
		case '1':
			// index 0 is Monday in the mask, weekday 1 in the array.
			week[(index+1)%7] = true
		case '0':
		default:
			return [7]bool{}, false
		}
	}
	return week, true
}

func buildGTFSRTCancellations(
	ctx context.Context,
	index *gtfsRTIndex,
	now time.Time,
	read gtfsRTDailyReader,
) ([]*gtfs.FeedEntity, map[gtfsRTRouteKey][]gtfsRTTrip, gtfsRTStats) {
	var stats gtfsRTStats
	weekday := int(now.Weekday())
	serviceDate := now.Format("20060102")

	active := make(map[gtfsRTRouteKey][]gtfsRTTrip, len(index.trips))
	uidSet := make(map[string]struct{}, len(index.trips))
	for key, trips := range index.trips {
		running := make([]gtfsRTTrip, 0, len(trips))
		for _, trip := range trips {
			if trip.week[weekday] {
				running = append(running, trip)
			}
		}
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

	daily, err := read(ctx, uids)
	if err != nil {
		zap.S().Errorw("read failed", "component", "gtfs_rt", "action", "daily", "event", "read_failed", "err", err)
		return nil, nil, stats
	}

	keys := make([]gtfsRTRouteKey, 0, len(active))
	for key := range active {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].subRouteUID != keys[j].subRouteUID {
			return keys[i].subRouteUID < keys[j].subRouteUID
		}
		return keys[i].direction < keys[j].direction
	})

	entities := make([]*gtfs.FeedEntity, 0, 512)
	// Every trip that survives is a candidate the matcher may assign a vehicle
	// to; a cancelled one never reaches this map.
	running := make(map[gtfsRTRouteKey][]gtfsRTTrip, len(active))
	for _, key := range keys {
		observed, ok := observedDepartures(daily[key.subRouteUID], key.direction)
		if !ok {
			stats.routesNoDaily++
			running[key] = active[key]
			continue
		}
		scheduled := make(map[int][]string, len(active[key]))
		for _, trip := range active[key] {
			scheduled[trip.departure] = append(scheduled[trip.departure], trip.tripID)
		}
		if !gtfsRTGatePasses(observed, scheduled) {
			// The two sources disagree about how this subroute names a departure,
			// so no cancellation can be proven — but neither is any trip proven
			// gone, so they all stay matchable.
			stats.routesGateFailed++
			running[key] = active[key]
			continue
		}
		for _, trip := range active[key] {
			if _, ran := observed[trip.departure]; ran {
				running[key] = append(running[key], trip)
			}
		}
		departures := make([]int, 0, len(scheduled))
		for departure := range scheduled {
			departures = append(departures, departure)
		}
		sort.Ints(departures)
		for _, departure := range departures {
			if _, ran := observed[departure]; ran {
				continue
			}
			for _, tripID := range scheduled[departure] {
				entities = append(entities, cancelledTripEntity(tripID, serviceDate))
				stats.cancellations++
			}
		}
	}
	return entities, running, stats
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
	if timetable == nil {
		return nil, false
	}
	directions := timetable.GetDirection()
	entry, ok := directions[direction]
	if !ok || entry == nil {
		return nil, false
	}
	observed := make(map[int]struct{}, len(entry.GetDailyTimetables()))
	for _, trip := range entry.GetDailyTimetables() {
		origin := originStopTime(trip)
		if origin == nil {
			continue
		}
		clock := origin.GetDepartureTime()
		if strings.TrimSpace(clock) == "" {
			clock = origin.GetArrivalTime()
		}
		minutes, parsed := parseGTFSRTClockTime(clock)
		if !parsed {
			// An unreadable departure cannot be matched, so it will fail the gate
			// and silence the subroute. That is the intended outcome: we cannot
			// tell which scheduled trip it accounts for.
			observed[-1] = struct{}{}
			continue
		}
		observed[minutes] = struct{}{}
	}
	return observed, true
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
	client := b.rc
	out := make(map[string]*models.Bus_DailyTimetables, len(subRouteUIDs))
	for start := 0; start < len(subRouteUIDs); start += _gtfsRTMGetBatch {
		end := min(start+_gtfsRTMGetBatch, len(subRouteUIDs))
		batch := subRouteUIDs[start:end]
		keys := make([]string, len(batch))
		for index, uid := range batch {
			keys[index] = shared.BusDailyTimetableKey(uid)
		}
		values, err := client.MGet(ctx, keys...).Result()
		if err != nil {
			return nil, _oops.Wrapf(err, "gtfs-rt: read daily timetables")
		}
		for index, value := range values {
			text, ok := value.(string)
			if !ok || text == "" {
				continue
			}
			timetable := &models.Bus_DailyTimetables{}
			if err := proto.Unmarshal([]byte(text), timetable); err != nil {
				// A corrupt payload is dropped rather than failing the tick: it
				// silences one subroute, which is the same outcome as a missing
				// key and is already the designed degradation.
				zap.S().Warnw("decode failed",
					"component", "gtfs_rt",
					"action", "daily",
					"event", "decode_failed",
					"subroute", batch[index],
					"err", err,
				)
				continue
			}
			out[batch[index]] = timetable
		}
	}
	return out, nil
}

// NewRTBuilder builds the GTFS-Realtime snapshot builder. It owns the static
// trip index between ticks, so the caller must keep one instance and never run
// two ticks concurrently.
func NewRTBuilder(db *pgxpool.Pool, rc *redis.Client) *gtfsRTBuilder {
	return &gtfsRTBuilder{db: db, rc: rc}
}
