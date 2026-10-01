package main

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

// _busDailyHourlyTimeout bounds one hourly bus_dailytimetable load. Only the
// cities whose landing marker moved are transformed, so a quiet hour costs one
// landing_state query and the full-refresh hour stays well inside this budget.
const _busDailyHourlyTimeout = 15 * time.Minute

func registerBusDailyTimetableCron(r *cron.Cron, rawPool, db *pgxpool.Pool, rc *redis.Client) {
	src := rawTDXSource{pool: rawPool}
	runner := newStaticPipelineRunner(rawPool, _busDailyHourlyTimeout)
	loaded := make(map[string]string)
	_, _ = addStaticCron(r, "0 10 * * * *", func() {
		err := runner.Run(context.Background(), func(ctx context.Context) error {
			return loadChangedBusDailyTimetables(ctx, rawPool, src, db, rc, loaded)
		})
		if err != nil {
			zap.S().Errorw("failed",
				"component", "load",
				"action", "bus_dailytimetable_hourly",
				"event", "failed",
				"err", err,
			)
		}
	})
}

// rawMarkerQuerier is the narrow read the hourly load needs from raw_tdx,
// kept separate from *pgxpool.Pool so the marker query is testable.
type rawMarkerQuerier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func busDailyLandingMarkers(ctx context.Context, q rawMarkerQuerier) (map[string]string, error) {
	rows, err := q.Query(ctx, `
		SELECT partition_value, last_modified
		FROM raw_tdx.landing_state
		WHERE table_name='bus_dailytimetable' AND partition_column='city'`)
	if err != nil {
		return nil, _oops.Wrapf(err, "read bus_dailytimetable landing markers")
	}
	defer rows.Close()
	markers := make(map[string]string, 32)
	for rows.Next() {
		var city, marker string
		if err := rows.Scan(&city, &marker); err != nil {
			return nil, _oops.Wrapf(err, "read bus_dailytimetable landing markers: scan")
		}
		markers[city] = marker
	}
	if err := rows.Err(); err != nil {
		return nil, _oops.Wrapf(err, "read bus_dailytimetable landing markers: rows")
	}
	return markers, nil
}

func busDailyPendingCities(markers, loaded map[string]string) []string {
	pending := make([]string, 0, len(markers))
	for city, marker := range markers {
		if bus.DailyTimetableLoadSkip(city) || loaded[city] == marker {
			continue
		}
		pending = append(pending, city)
	}
	sort.Strings(pending)
	return pending
}

func loadChangedBusDailyTimetables(
	ctx context.Context,
	q rawMarkerQuerier,
	src pipeline.LoadSource,
	db *pgxpool.Pool,
	rc *redis.Client,
	loaded map[string]string,
) error {
	markers, err := busDailyLandingMarkers(ctx, q)
	if err != nil {
		return err
	}
	base, err := busDailyTimetableSpec(src)
	if err != nil {
		return err
	}
	pending := busDailyPendingCities(markers, loaded)
	var failures []error
	for _, city := range pending {
		spec := base
		spec.partitions = func() []string { return []string{city} }
		if _, err := runLoadSpecs(ctx, src, db, rc, []loadSpec{spec}); err != nil {
			failures = append(failures, err)
			continue
		}
		loaded[city] = markers[city]
	}
	zap.S().Infow("done",
		"component", "load",
		"action", "bus_dailytimetable_hourly",
		"event", "done",
		"changed", len(pending),
		"failed", len(failures),
	)
	return errors.Join(failures...)
}

// busDailyTimetableSpec pulls the daily-timetable loader recipe out of the
// registry so the hourly path reuses the same transform, staleness rule and
// partition column as the 03:30 run.
func busDailyTimetableSpec(src pipeline.LoadSource) (loadSpec, error) {
	for _, spec := range loaderRegistry(src) {
		if spec.key == "bus_dailytimetable" {
			return spec, nil
		}
	}
	return loadSpec{}, errors.New("bus daily timetable: loader spec missing from registry")
}
