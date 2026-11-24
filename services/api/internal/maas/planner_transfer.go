package maas

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"go.uber.org/zap"
)

// _tightTransferMargin is the slack below which a transfer reads as easy to
// miss.
const _tightTransferMargin = 3 * time.Minute

// addPlannerTransfers also takes the transfer buffer back out of the
// itinerary's walking: plannerQuery asked MOTIS to add it to every transfer
// walk.
func addPlannerTransfers(response *pb.PlannerResponse, estimated map[*pb.PlannerLeg]bool, bufferSeconds int64) {
	for _, itinerary := range response.Itineraries {
		var buffered int64
		itinerary.Transfers, buffered = plannerTransfers(itinerary.Legs, estimated, bufferSeconds)
		itinerary.WalkSeconds -= buffered
	}
}

// plannerTransfers pairs consecutive transit legs. MOTIS joins stay-seated
// (interlined) legs into one unless asked not to, so every pair is a change.
// It also returns the buffer it took out of the walks: a change that walks
// less than the buffer, such as a same-stop change MOTIS emitted no walk leg
// for, gives back only what it walked.
func plannerTransfers(legs []*pb.PlannerLeg, estimated map[*pb.PlannerLeg]bool, bufferSeconds int64) ([]*pb.PlannerTransfer, int64) {
	var transfers []*pb.PlannerTransfer
	var buffered int64
	arrived, walk := -1, int64(0)
	for i, leg := range legs {
		if leg.Kind != pb.PlannerLegKind_PLANNER_LEG_KIND_TRANSIT {
			walk += leg.DurationSeconds
			continue
		}
		if arrived >= 0 {
			buffer := min(walk, bufferSeconds)
			buffered += buffer
			transfers = append(transfers, plannerTransfer(legs, arrived, i, walk-buffer, estimated[legs[arrived]]))
		}
		arrived, walk = i, 0
	}
	return transfers, buffered
}

func plannerTransfer(legs []*pb.PlannerLeg, from, to int, walk int64, estimated bool) *pb.PlannerTransfer {
	arrival, departure := legs[from], legs[to]
	margin := departure.GetStartTime().GetSeconds() - arrival.GetEndTime().GetSeconds() - walk
	return &pb.PlannerTransfer{
		FromLeg:        int32(from),
		ToLeg:          int32(to),
		MarginSeconds:  margin,
		Level:          transferLevel(arrival, departure, margin),
		TimesEstimated: estimated,
	}
}

func transferLevel(from, to *pb.PlannerLeg, margin int64) pb.TransferLevel {
	if !transferTimed(from, to) {
		return pb.TransferLevel_TRANSFER_LEVEL_UNSPECIFIED
	}
	if margin < int64(_tightTransferMargin/time.Second) {
		return pb.TransferLevel_TRANSFER_LEVEL_TIGHT
	}
	return pb.TransferLevel_TRANSFER_LEVEL_COMFORTABLE
}

func transferTimed(from, to *pb.PlannerLeg) bool {
	return from.EndTime != nil && to.StartTime != nil
}

// _estimatedLegSQL returns the legs that ride at least one stop-to-stop hop
// whose bus_segment_time row is distance-estimated (sample_count = 0). Those
// are the hops the GTFS feed lays origin-only schedules out from. A hop with no
// row at all belongs to a published timetable and says nothing either way.
const _estimatedLegSQL = `
	WITH input AS (
		SELECT *
		FROM unnest($1::integer[], $2::text[], $3::integer[], $4::text[], $5::text[])
			AS request(leg_index, sub_route_uid, direction, from_stop_uid, to_stop_uid)
	), span AS (
		SELECT request.leg_index, request.sub_route_uid, request.direction,
			boarding.stop_sequence AS from_sequence, alighting.stop_sequence AS to_sequence
		FROM input request
		JOIN bus_station_stop_map boarding
		  ON boarding.sub_route_uid = request.sub_route_uid AND boarding.direction = request.direction
		 AND boarding.stop_uid = request.from_stop_uid
		JOIN bus_station_stop_map alighting
		  ON alighting.sub_route_uid = request.sub_route_uid AND alighting.direction = request.direction
		 AND alighting.stop_uid = request.to_stop_uid
		 AND alighting.stop_sequence > boarding.stop_sequence
	), hop AS (
		SELECT span.leg_index, span.sub_route_uid, span.direction, stop.stop_uid,
			LAG(stop.stop_uid) OVER (PARTITION BY span.leg_index ORDER BY stop.stop_sequence) AS previous_stop_uid
		FROM span
		JOIN bus_station_stop_map stop
		  ON stop.sub_route_uid = span.sub_route_uid AND stop.direction = span.direction
		 AND stop.stop_sequence BETWEEN span.from_sequence AND span.to_sequence
	)
	SELECT DISTINCT hop.leg_index
	FROM hop
	JOIN bus_segment_time segment
	  ON segment.sub_route_uid = hop.sub_route_uid AND segment.direction = hop.direction
	 AND segment.from_stop_uid = hop.previous_stop_uid AND segment.to_stop_uid = hop.stop_uid
	WHERE segment.sample_count = 0`

// busSegmentBatch is one row per bus leg whose MOTIS ids name a subroute,
// direction and stop pair.
type busSegmentBatch struct {
	legs                       []*pb.PlannerLeg
	indices, directions        []int32
	subRoutes, boards, alights []string
}

func (b *busSegmentBatch) add(leg *pb.PlannerLeg) {
	subRoute, direction, ok := busTripRoute(leg.GetTransit().GetTripId())
	board, boardOK := gtfsStopUID(leg.GetFrom().GetStopId())
	alight, alightOK := gtfsStopUID(leg.GetTo().GetStopId())
	if !ok || !boardOK || !alightOK {
		return
	}
	b.indices = append(b.indices, int32(len(b.legs)))
	b.legs = append(b.legs, leg)
	b.subRoutes, b.directions = append(b.subRoutes, subRoute), append(b.directions, direction)
	b.boards, b.alights = append(b.boards, board), append(b.alights, alight)
}

func isPlannerBusLeg(leg *pb.PlannerLeg) bool {
	return leg.Mode == pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS ||
		leg.Mode == pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_COACH
}

// busTripRoute reads the subroute and direction out of a MOTIS trip id,
// "<service day>_<start>_<dataset>_<GTFS trip_id>", where the GTFS feed builds
// a bus trip_id as "<SubRouteUID>:<direction>:<departure>:<weekdays>".
func busTripRoute(tripID string) (string, int32, bool) {
	parts := strings.SplitN(tripID, "_", 4)
	if len(parts) != 4 {
		return "", 0, false
	}
	subRoute, rest, _ := strings.Cut(parts[3], ":")
	directionText, _, _ := strings.Cut(rest, ":")
	direction, err := strconv.ParseInt(directionText, 10, 32)
	if err != nil {
		return "", 0, false
	}
	return subRoute, int32(direction), true
}

// gtfsStopUID strips the "<dataset>_" prefix MOTIS puts on a GTFS stop_id.
func gtfsStopUID(stopID string) (string, bool) {
	_, uid, ok := strings.Cut(stopID, "_")
	return uid, ok && uid != ""
}

func estimatedLegs(ctx context.Context, db maasDB, pairs []plannerPair) map[*pb.PlannerLeg]bool {
	batch := collectBusSegmentBatch(pairs)
	if db == nil || len(batch.legs) == 0 {
		return nil
	}
	return queryEstimatedLegs(ctx, db, batch)
}

func collectBusSegmentBatch(pairs []plannerPair) busSegmentBatch {
	var batch busSegmentBatch
	for _, pair := range pairs {
		if isPlannerBusLeg(pair.leg) {
			batch.add(pair.leg)
		}
	}
	return batch
}

func queryEstimatedLegs(ctx context.Context, db maasDB, batch busSegmentBatch) map[*pb.PlannerLeg]bool {
	rows, err := db.Query(ctx, _estimatedLegSQL, batch.indices, batch.subRoutes, batch.directions, batch.boards, batch.alights)
	if err != nil {
		logEstimatedLegs("query_error", err)
		return nil
	}
	defer rows.Close()
	return readEstimatedLegs(rows, batch.legs)
}

// readEstimatedLegs keeps what it read before a failure: each row it did read
// names a leg that really rides an estimated hop.
func readEstimatedLegs(rows pgx.Rows, legs []*pb.PlannerLeg) map[*pb.PlannerLeg]bool {
	estimated := make(map[*pb.PlannerLeg]bool)
	for rows.Next() {
		var index int32
		if err := rows.Scan(&index); err != nil {
			logEstimatedLegs("scan_error", err)
			return estimated
		}
		estimated[legs[index]] = true
	}
	if err := rows.Err(); err != nil {
		logEstimatedLegs("iterate_error", err)
	}
	return estimated
}

func logEstimatedLegs(event string, err error) {
	zap.S().Errorw(strings.ReplaceAll(event, "_", " "),
		"component", "maas",
		"action", "estimated_legs",
		"event", event,
		"err", err,
	)
}
