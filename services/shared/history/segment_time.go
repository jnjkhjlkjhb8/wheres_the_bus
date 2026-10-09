package history

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	_segmentUpsertBatch = 2000
	// Segments outside these bounds are dropped rather than recorded. Below five
	// seconds is two stops sharing a position; above thirty minutes is a vehicle
	// that went out of service, or two runs of one plate stitched together.
	_segmentMinSecs = 5
	_segmentMaxSecs = 1800
)

func upsertSegmentTimes(ctx context.Context, db *pgxpool.Pool, segs []SegmentObs) (int64, error) {
	stmt := `
		INSERT INTO bus_segment_time
		  (sub_route_uid, direction, from_stop_uid, to_stop_uid, secs, sample_count, updated_at)
		SELECT u.sub_route_uid, u.Direction, u.from_stop_uid, u.to_stop_uid,
		       u.secs, u.sample_count, now()
		FROM unnest($1::text[], $2::smallint[], $3::text[], $4::text[], $5::int[], $6::int[])
		     AS u(sub_route_uid, direction, from_stop_uid, to_stop_uid, secs, sample_count)
		ON CONFLICT (sub_route_uid, direction, from_stop_uid, to_stop_uid)
		DO UPDATE SET secs         = EXCLUDED.secs,
		              sample_count = EXCLUDED.sample_count,
		              updated_at   = now()`
	var total int64
	for start := 0; start < len(segs); start += _segmentUpsertBatch {
		batch := segs[start:min(start+_segmentUpsertBatch, len(segs))]
		subRoutes := make([]string, len(batch))
		directions := make([]int16, len(batch))
		fromStops := make([]string, len(batch))
		toStops := make([]string, len(batch))
		secs := make([]int32, len(batch))
		samples := make([]int32, len(batch))
		for i, s := range batch {
			subRoutes[i], directions[i] = s.SubRouteUID, s.Direction
			fromStops[i], toStops[i] = s.fromStopUID, s.toStopUID
			secs[i], samples[i] = int32(s.secs), int32(s.sampleCount)
		}
		tag, err := db.Exec(ctx, stmt, subRoutes, directions, fromStops, toStops, secs, samples)
		if err != nil {
			return total, _oops.With("start", start).With("end", start+len(batch)).Wrapf(err, "upsert segments")
		}
		total += tag.RowsAffected()
	}
	return total, nil
}
