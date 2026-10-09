package gtfs

import (
	"context"
	"strconv"
	"time"

	"github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

type railDelayTrip struct {
	tripID   string
	stations map[string]bool
}

const _railDelayIndexSQL = `
SELECT train_no, trip_id, stations FROM gtfs_rt_rail_trip
WHERE run_id = $1 AND service_date = $2::date`

// gtfsRTRailDelayStats records why a reported delay did not reach the feed. The
// producer is deliberately silent in several cases, so the silence has to be
// measurable or its coverage is unknowable.
type gtfsRTRailDelayStats struct {
	delaysRead     int
	delaysOnTime   int
	trainNotToday  int
	stationUnknown int
	updates        int
}

// loadRailDelayIndex reads today's TRA trains. It is refreshed on the same daily
// cadence as the bus index: a train number is reused across days, so an index
// built for yesterday would name yesterday's trip.
func loadRailDelayIndex(ctx context.Context, db *pgxpool.Pool, runID, today string) (map[string]railDelayTrip, error) {
	rows, err := db.Query(ctx, _railDelayIndexSQL, runID, today)
	if err != nil {
		return nil, _oops.Wrapf(err, "gtfs-rt: load rail delay index")
	}
	defer rows.Close()
	index := make(map[string]railDelayTrip, 2048)
	for rows.Next() {
		var trainNo, tripID string
		var stations []string
		if err := rows.Scan(&trainNo, &tripID, &stations); err != nil {
			return nil, _oops.Wrapf(err, "gtfs-rt: load rail delay index: scan")
		}
		set := make(map[string]bool, len(stations))
		for _, station := range stations {
			set[station] = true
		}
		index[trainNo] = railDelayTrip{tripID: tripID, stations: set}
	}
	if err := rows.Err(); err != nil {
		return nil, _oops.Wrapf(err, "gtfs-rt: load rail delay index: rows")
	}
	return index, nil
}

// readRailDelays reads the two hashes rail.TraEta writes: the delay in minutes and
// the station it was measured at. A train present in one and not the other is
// left to buildGTFSRTRailDelays to drop.
func readRailDelays(ctx context.Context, rc *redis.Client) (map[string]string, map[string]string, error) {
	minutes, err := rc.HGetAll(ctx, shared.TraDelayHashKey).Result()
	if err != nil {
		return nil, nil, _oops.Wrapf(err, "gtfs-rt: read TRA delays")
	}
	stations, err := rc.HGetAll(ctx, shared.TraDelayStationKey).Result()
	if err != nil {
		return nil, nil, _oops.Wrapf(err, "gtfs-rt: read TRA delay stations")
	}
	return minutes, stations, nil
}

func buildGTFSRTRailDelays(
	index map[string]railDelayTrip,
	minutes, stations map[string]string,
	now time.Time,
) ([]*gtfs.FeedEntity, gtfsRTRailDelayStats) {
	stats := gtfsRTRailDelayStats{delaysRead: len(minutes)}
	date := now.Format("20060102")
	entities := make([]*gtfs.FeedEntity, 0, len(minutes))
	for trainNo, raw := range minutes {
		late, err := strconv.Atoi(raw)
		if err != nil {
			continue
		}
		if late <= 0 {
			stats.delaysOnTime++
			continue
		}
		trip, running := index[trainNo]
		if !running {
			stats.trainNotToday++
			continue
		}
		station := stations[trainNo]
		if station == "" || !trip.stations[station] {
			stats.stationUnknown++
			continue
		}
		stats.updates++
		entities = append(entities, &gtfs.FeedEntity{
			Id: proto.String(trip.tripID),
			TripUpdate: &gtfs.TripUpdate{
				Trip: &gtfs.TripDescriptor{
					TripId:               proto.String(trip.tripID),
					StartDate:            proto.String(date),
					ScheduleRelationship: gtfs.TripDescriptor_SCHEDULED.Enum(),
				},
				StopTimeUpdate: []*gtfs.TripUpdate_StopTimeUpdate{{
					StopId: proto.String(railDelayStopID(station)),
					// Arrival only: GTFS-RT reads a missing departure as carrying
					// the same delay, and a train held at a platform is the one
					// case where stating both would be inventing the difference.
					Arrival: &gtfs.TripUpdate_StopTimeEvent{
						Delay: proto.Int32(int32(late) * 60),
					},
				}},
			},
		})
	}
	return entities, stats
}

// railDelayStopID is the platform stop_times references, which is what a
// StopTimeUpdate has to name: the station node itself is a parent station and no
// trip calls at it.
func railDelayStopID(stationID string) string {
	return "TRA:" + stationID + ":platform"
}

// logGTFSRTRailDelayStats reports the producer's coverage. Every drop is a delay TDX
// published that the feed does not carry, so the counters are the only way to
// tell a quiet day from a broken join.
func logGTFSRTRailDelayStats(stats gtfsRTRailDelayStats) {
	zap.S().Infow("built",
		"component", "gtfs_rt",
		"action", "delay",
		"event", "built",
		"delays_read", stats.delaysRead,
		"delays_on_time", stats.delaysOnTime,
		"train_not_today", stats.trainNotToday,
		"station_unknown", stats.stationUnknown,
		"updates", stats.updates,
	)
}
