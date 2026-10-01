package history

import (
	"context"
	"math"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"go.uber.org/zap"
)

// predictionSource labels which prediction tier produced an ETA, so accuracy can
// be compared tier by tier. Values match the source column of
// bus_eta_prediction_error.
const (
	SourceTDX         = "tdx"
	SourcePropagation = "propagation"
	SourceModel       = "model"
	SourceSchedule    = "schedule"
)

// PredictionRecord is one prediction awaiting an actual: a predicted arrival at
// (route, direction, stop) made at predictedAt by source, in seconds-to-arrival.
type PredictionRecord struct {
	SubRouteUID   string
	Direction     int16
	StopUID       string
	Source        string
	PredictedAt   time.Time
	PredictedSecs int
}

// arrivalEvent is one observed vehicle arrival at a stop: the moment the vehicle
// reached (or passed) the stop, derived from an estimate crossing zero.
type arrivalEvent struct {
	SubRouteUID string
	Direction   int16
	StopUID     string
	arrivedAt   time.Time
}

// matchedError pairs a prediction with the actual arrival it predicted and the
// error in seconds (predicted minus actual arrival time). It is one row for
// bus_eta_prediction_error / one sample for MAE.
type matchedError struct {
	SubRouteUID   string
	Direction     int16
	StopUID       string
	Source        string
	PredictedAt   time.Time
	PredictedSecs int
	actualSecs    int
}

func matchPredictionActual(preds []PredictionRecord, arrivals []arrivalEvent, matchWindow time.Duration) []matchedError {
	sorted := append([]arrivalEvent(nil), arrivals...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].arrivedAt.Before(sorted[j].arrivedAt) })

	out := make([]matchedError, 0, len(preds))
	for _, p := range preds {
		var matched *arrivalEvent
		for i := range sorted {
			a := &sorted[i]
			if a.SubRouteUID != p.SubRouteUID || a.Direction != p.Direction || a.StopUID != p.StopUID {
				continue
			}
			if a.arrivedAt.Before(p.PredictedAt) {
				continue
			}
			if a.arrivedAt.Sub(p.PredictedAt) > matchWindow {
				break
			}
			matched = a
			break
		}
		if matched == nil {
			continue
		}
		out = append(out, matchedError{
			SubRouteUID:   p.SubRouteUID,
			Direction:     p.Direction,
			StopUID:       p.StopUID,
			Source:        p.Source,
			PredictedAt:   p.PredictedAt,
			PredictedSecs: p.PredictedSecs,
			actualSecs:    int(matched.arrivedAt.Sub(p.PredictedAt).Round(time.Second).Seconds()),
		})
	}
	return out
}

// maeKey groups matched errors for aggregation: per route and prediction source.
type maeKey struct {
	SubRouteUID string
	Source      string
}

// maeStat is the aggregated accuracy for one (route, source): mean absolute
// error in seconds over n samples.
type maeStat struct {
	SubRouteUID string
	Source      string
	maeSeconds  float64
	samples     int
}

// aggregateMAE computes mean absolute error (|predicted - actual| seconds) per
// route per source. Results are sorted by route then source for a stable,
// scannable log. An empty input yields an empty slice.
func aggregateMAE(errs []matchedError) []maeStat {
	type acc struct {
		sumAbs float64
		n      int
	}
	buckets := make(map[maeKey]*acc)
	for _, e := range errs {
		k := maeKey{SubRouteUID: e.SubRouteUID, Source: e.Source}
		a := buckets[k]
		if a == nil {
			a = &acc{}
			buckets[k] = a
		}
		a.sumAbs += math.Abs(float64(e.PredictedSecs - e.actualSecs))
		a.n++
	}
	out := make([]maeStat, 0, len(buckets))
	for k, a := range buckets {
		mae := 0.0
		if a.n > 0 {
			mae = a.sumAbs / float64(a.n)
		}
		out = append(out, maeStat{SubRouteUID: k.SubRouteUID, Source: k.Source, maeSeconds: mae, samples: a.n})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].SubRouteUID != out[j].SubRouteUID {
			return out[i].SubRouteUID < out[j].SubRouteUID
		}
		return out[i].Source < out[j].Source
	})
	return out
}

// _predictionMatchWindow bounds how long after a prediction an arrival may occur
// and still be treated as the arrival that prediction was about.
const _predictionMatchWindow = 30 * time.Minute

// _predictionLookback is how far back MeasurePredictionError considers still-open
// predictions, and therefore how much arrival history it needs to load.
const _predictionLookback = 24 * time.Hour

// loadOpenPredictions reads predictions from the last day that have no actual
// yet. Postgres owns bus_eta_prediction_error; only the arrivals moved.
func loadOpenPredictions(ctx context.Context, db *pgxpool.Pool) ([]PredictionRecord, error) {
	rows, err := db.Query(ctx, `
		SELECT sub_route_uid, direction, stop_uid, source, predicted_at, predicted_seconds
		FROM bus_eta_prediction_error
		WHERE actual_seconds IS NULL AND predicted_at >= NOW() - INTERVAL '1 day'`)
	if err != nil {
		return nil, _oops.Wrapf(err, "query open predictions")
	}
	defer rows.Close()
	var out []PredictionRecord
	for rows.Next() {
		var p PredictionRecord
		if err := rows.Scan(&p.SubRouteUID, &p.Direction, &p.StopUID, &p.Source,
			&p.PredictedAt, &p.PredictedSecs); err != nil {
			return nil, _oops.Wrapf(err, "scan open prediction")
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func writePredictionActuals(ctx context.Context, db *pgxpool.Pool, matched []matchedError) (int64, error) {
	if len(matched) == 0 {
		return 0, nil
	}
	uids := make([]string, len(matched))
	dirs := make([]int16, len(matched))
	stops := make([]string, len(matched))
	sources := make([]string, len(matched))
	at := make([]time.Time, len(matched))
	actual := make([]int32, len(matched))
	for i, m := range matched {
		uids[i], dirs[i], stops[i] = m.SubRouteUID, m.Direction, m.StopUID
		sources[i], at[i], actual[i] = m.Source, m.PredictedAt, int32(m.actualSecs)
	}
	tag, err := db.Exec(ctx, `
		UPDATE bus_eta_prediction_error pe
		SET actual_seconds = v.actual_seconds
		FROM unnest($1::text[], $2::smallint[], $3::text[], $4::text[],
		            $5::timestamptz[], $6::int[])
		       AS v(sub_route_uid, direction, stop_uid, source, predicted_at, actual_seconds)
		WHERE pe.sub_route_uid = v.sub_route_uid
		  AND pe.Direction     = v.Direction
		  AND pe.stop_uid      = v.stop_uid
		  AND pe.Source        = v.Source
		  AND pe.predicted_at  = v.predicted_at
		  AND pe.actual_seconds IS NULL`,
		uids, dirs, stops, sources, at, actual)
	if err != nil {
		return 0, _oops.Wrapf(err, "write prediction actuals")
	}
	return tag.RowsAffected(), nil
}

// fillPredictionActuals pairs still-open predictions with the arrivals they
// predicted and writes the results back. A disabled history host leaves the
// predictions open for a later run rather than failing the job.
func fillPredictionActuals(ctx context.Context, db *pgxpool.Pool, hist Reader) (int64, error) {
	if hist == nil {
		zap.S().Warnw("skipped fill", "component", "eta_error", "event", "skipped_fill", "reason", "history_disabled")
		return 0, nil
	}
	preds, err := loadOpenPredictions(ctx, db)
	if err != nil {
		return 0, obs.Transient(_oops.Wrapf(err, "load open predictions"))
	}
	if len(preds) == 0 {
		return 0, nil
	}
	arrivals, err := hist.arrivals(ctx, time.Now().Add(-_predictionLookback))
	if err != nil {
		return 0, obs.Transient(_oops.Wrapf(err, "load history arrivals"))
	}
	n, err := writePredictionActuals(ctx, db, matchPredictionActual(preds, arrivals, _predictionMatchWindow))
	if err != nil {
		return 0, obs.Transient(_oops.Wrapf(err, "fill prediction actuals"))
	}
	return n, nil
}

func MeasurePredictionError(ctx context.Context, db *pgxpool.Pool, hist Reader) error {
	zap.S().Infow("start", "component", "eta_error")

	filled, err := fillPredictionActuals(ctx, db, hist)
	if err != nil {
		return err
	}
	zap.S().Infow("filled actuals", "component", "eta_error", "actuals", filled)

	rows, err := db.Query(ctx, `
		SELECT sub_route_uid, source,
		       AVG(ABS(predicted_seconds - actual_seconds))::float AS mae,
		       COUNT(*) AS samples
		FROM bus_eta_prediction_error
		WHERE actual_seconds IS NOT NULL
		  AND predicted_at >= NOW() - INTERVAL '1 day'
		GROUP BY sub_route_uid, source
		ORDER BY sub_route_uid, source`)
	if err != nil {
		return obs.Transient(_oops.Wrapf(err, "aggregate prediction error"))
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var sub, source string
		var mae float64
		var samples int
		if err := rows.Scan(&sub, &source, &mae, &samples); err != nil {
			zap.S().Errorw("scan error", "component", "eta_error", "err", err)
			continue
		}
		zap.S().Infow("log",
			"component", "eta_error",
			"sub_route", sub,
			"source", source,
			"mae_seconds", mae,
			"samples", samples,
		)
		count++
	}
	if err := rows.Err(); err != nil {
		return obs.Transient(_oops.Wrapf(err, "aggregate prediction error rows"))
	}
	zap.S().Infow("complete", "component", "eta_error", "groups", count)
	return nil
}

func RecordPredictionErrors(ctx context.Context, db *pgxpool.Pool, preds []PredictionRecord) {
	if len(preds) == 0 {
		return
	}
	rows := make([][]any, 0, len(preds))
	for _, p := range preds {
		rows = append(rows, []any{
			p.SubRouteUID, p.Direction, p.StopUID, p.Source, p.PredictedAt, p.PredictedSecs,
		})
	}
	cols := []string{"sub_route_uid", "direction", "stop_uid", "source", "predicted_at", "predicted_seconds"}
	_, err := db.CopyFrom(ctx, pgx.Identifier{"bus_eta_prediction_error"}, cols, pgx.CopyFromRows(rows))
	if err != nil {
		zap.S().Errorw("insert predictions error", "component", "eta_error", "rows", len(rows), "err", err)
	}
}
