package history

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"go.uber.org/zap"
)

const (
	// _segmentDiffMinSecs / segmentDiffMaxSecs match segmentMinSecs/segmentMaxSecs:
	// both bound one hop's running time, and a disagreement would put two
	// different definitions of "plausible" in one table.
	_segmentDiffMinSecs = _segmentMinSecs
	_segmentDiffMaxSecs = _segmentMaxSecs
	_segmentDiffWindow  = 14 * 24 * time.Hour
	// _segmentRateMinHops is how many observed hops a route direction needs before
	// its own pace is used instead of its city's. Below it the median is drawn
	// from too few segments to describe the route.
	_segmentRateMinHops      = 5
	_segmentEstimatedSamples = 0
)

func ComputeSegmentTimesFromEstimates(ctx context.Context, db *pgxpool.Pool, hist Reader) error {
	if db == nil {
		return nil
	}
	if hist == nil {
		zap.S().Warnw("skipped", "component", "segment_time_eta", "reason", "history_disabled")
		return nil
	}
	zap.S().Infow("start", "component", "segment_time_eta")
	started := time.Now()
	segs, err := hist.segmentsByEstimate(ctx, _segmentDiffWindow)
	if err != nil {
		return obs.Transient(_oops.Wrapf(err, "read estimate segments"))
	}
	n, err := upsertSegmentTimes(ctx, db, segs)
	if err != nil {
		return obs.Transient(_oops.Wrapf(err, "rebuild bus segment times from estimates"))
	}
	zap.S().Infow("complete",
		"component", "segment_time_eta",
		"segments", n,
		"elapsed", time.Since(started).Round(time.Millisecond),
	)
	return nil
}

func FillSegmentTimesFromDistance(ctx context.Context, db *pgxpool.Pool) error {
	if db == nil {
		return nil
	}
	zap.S().Infow("start", "component", "segment_time_fill")
	started := time.Now()
	tag, err := db.Exec(ctx, `
		WITH hop AS (
			-- Every adjacent pair the network needs, from the same stop map the
			-- feed is joined against.
			SELECT sub_route_uid, direction, stop_uid, station_id, stop_sequence,
			       LEAD(stop_uid)      OVER w AS next_stop_uid,
			       LEAD(station_id)    OVER w AS next_station_id,
			       LEAD(stop_sequence) OVER w AS next_stop_sequence
			FROM bus_station_stop_map
			WINDOW w AS (PARTITION BY sub_route_uid, direction ORDER BY stop_sequence)
		), geo AS (
			SELECT h.sub_route_uid, h.Direction, h.stop_uid, h.next_stop_uid,
			       ST_DistanceSphere(a.position, b.position) AS dist
			FROM hop h
			JOIN bus_stations a ON a.station_uid = h.station_id
			JOIN bus_stations b ON b.station_uid = h.next_station_id
			WHERE h.next_stop_sequence = h.stop_sequence + 1
		), observed AS (
			-- Pace is read back from what the observation passes wrote, so the
			-- estimate tracks the network's real speed rather than a constant.
			SELECT g.sub_route_uid, g.Direction, t.secs / g.dist AS rate
			FROM bus_segment_time t
			JOIN geo g ON g.sub_route_uid = t.sub_route_uid
			          AND g.Direction     = t.Direction
			          AND g.stop_uid      = t.from_stop_uid
			          AND g.next_stop_uid = t.to_stop_uid
			WHERE t.sample_count > 0 AND g.dist > 0
		), rate_route AS (
			SELECT sub_route_uid, direction,
			       percentile_cont(0.5) WITHIN GROUP (ORDER BY rate) AS rate
			FROM observed GROUP BY 1, 2 HAVING count(*) >= $1
		), rate_city AS (
			SELECT left(sub_route_uid, 3) AS pfx,
			       percentile_cont(0.5) WITHIN GROUP (ORDER BY rate) AS rate
			FROM observed GROUP BY 1
		), rate_all AS (
			SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY rate) AS rate FROM observed
		)
		INSERT INTO bus_segment_time
		  (sub_route_uid, direction, from_stop_uid, to_stop_uid, secs, sample_count, updated_at)
		SELECT g.sub_route_uid, g.Direction, g.stop_uid, g.next_stop_uid,
		       GREATEST($2, LEAST($3,
		         (g.dist * COALESCE(rr.rate, rc.rate, ra.rate))::int)),
		       $4, now()
		FROM geo g
		LEFT JOIN rate_route rr ON rr.sub_route_uid = g.sub_route_uid AND rr.Direction = g.Direction
		LEFT JOIN rate_city  rc ON rc.pfx = left(g.sub_route_uid, 3)
		CROSS JOIN rate_all ra
		WHERE g.dist > 0
		  AND COALESCE(rr.rate, rc.rate, ra.rate) IS NOT NULL
		-- Only genuinely empty hops. An existing row, observed or estimated, is
		-- left exactly as it is.
		ON CONFLICT (sub_route_uid, direction, from_stop_uid, to_stop_uid) DO NOTHING`,
		_segmentRateMinHops, _segmentDiffMinSecs, _segmentDiffMaxSecs, _segmentEstimatedSamples)
	if err != nil {
		return obs.Transient(_oops.Wrapf(err, "fill bus segment times from distance"))
	}
	zap.S().Infow("complete",
		"component", "segment_time_fill",
		"estimated", tag.RowsAffected(),
		"elapsed", time.Since(started).Round(time.Millisecond),
	)
	return nil
}
