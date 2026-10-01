package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/raw"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

// rawFetcher is the context-aware, disk-spooled conditional-fetch surface used
// by the static ingestor. *shared.TDXClient is the production implementation;
// tests use a bounded fake to verify fan-out and error aggregation.
type rawFetcher interface {
	GetInto(context.Context, string, string, func(shared.TDXIntoCommit) error) (shared.TDXIntoResult, error)
}

var _ rawFetcher = (*shared.TDXClient)(nil)

// ROLE=ingestor fetches static TDX endpoints and lands the raw payloads into
// raw_tdx (via dumpRawTDX in fetchRaw's GetInto commit). No transforms, no
// per-env writes.

// _ingestBusAPIs lists the TDX Bus static endpoints landed for every city in one
// ingestor run.
var _ingestBusAPIs = []string{
	"Route", "StopOfRoute", "Shape", "Schedule", "Station", "StationGroup",
	"Operator", "RouteFare", "DailyTimeTable", "DisplayStopOfRoute",
}

const _ingestTimeout = 20 * time.Minute

// _busDailyIngestTimeout bounds one hourly bus_dailytimetable landing. It is a
// single dataset over ~23 city partitions, most of them answering 304, so it
// needs far less than the full run's budget.
const _busDailyIngestTimeout = 10 * time.Minute

const _fullRelandWeekday = time.Sunday

func registerIngestorCrons(r *cron.Cron, tdx *shared.TDXClient, rawPool *pgxpool.Pool, boot *sync.WaitGroup) {
	runner := newStaticPipelineRunner(rawPool, _ingestTimeout)
	_, _ = addStaticCron(r, "0 0 3 * * *", func() {
		pipeline.RunDaily("ingest", _ingestTimeout, func(ctx context.Context) error {
			return runner.Run(ctx, func(ctx context.Context) error {
				return ingestRaw(ctx, tdx)
			})
		})
	})
	hourly := newStaticPipelineRunner(rawPool, _busDailyIngestTimeout)
	_, _ = addStaticCron(r, "0 0 * * * *", func() {
		pipeline.RunDaily("ingest_bus_dailytimetable", _busDailyIngestTimeout, func(ctx context.Context) error {
			return hourly.Run(ctx, func(ctx context.Context) error {
				var taipeiErr error
				if hasTDXCredentials() {
					taipeiErr = bus.LandDataTaipeiDailyTimetable(ctx, bus.NewDataTaipeiFeed(dataset.DataTaipeiCity), time.Now)
				}
				return errors.Join(ingestRaw(ctx, tdx, "bus_dailytimetable"), taipeiErr)
			})
		})
	})
	if os.Getenv("INGEST_ON_BOOT") == "true" {
		zap.S().Infow("\u2014 running once on boot", "component", "ingest", "INGEST_ON_BOOT", "true")
		trackBoot(boot, func() {
			if err := runner.Run(context.Background(), func(ctx context.Context) error {
				return ingestRaw(ctx, tdx)
			}); err != nil {
				zap.S().Errorw("failed", "component", "ingest", "action", "boot", "event", "failed", "err", err)
			}
		})
	} else {
		zap.S().Warnw("INGEST_ON_BOOT not set \u2014 boot run skipped, daily cron only", "component", "ingest")
	}
}

func hasTDXCredentials() bool {
	return os.Getenv("TDX_CLIENT_ID") != "" && os.Getenv("TDX_CLIENT_SECRET") != ""
}

func ingestRaw(ctx context.Context, tdx rawFetcher, tables ...string) error {
	if !hasTDXCredentials() {
		zap.S().Infow("idle", "component", "ingest", "action", "raw", "event", "idle", "reason", "no_credentials")
		return nil
	}

	scope := "all"
	only := map[string]bool{}
	if len(tables) > 0 {
		scope = strings.Join(tables, ",")
		for _, t := range tables {
			only[t] = true
		}
	}
	fullReland := len(only) == 0 && time.Now().In(pipeline.Taipei).Weekday() == _fullRelandWeekday
	zap.S().Infow("start",
		"component", "ingest",
		"action", "raw",
		"event", "start",
		"scope", scope,
		"full_reland", fullReland,
	)
	landingCycle, err := raw.NewLandingCycle()
	if err != nil {
		return _oops.Wrapf(err, "start raw landing cycle")
	}

	type job struct{ url, name string }
	var jobs []job
	for _, d := range dataset.Registry() {
		if !d.Fetched() {
			continue
		}
		if len(only) > 0 && !only[d.RawTable] {
			continue
		}
		for _, part := range d.Partitions() {
			jobs = append(jobs, job{d.URL(part), d.Name(part)})
		}
	}

	sem := make(chan struct{}, 3)
	var wg sync.WaitGroup
	failures := make(chan error, len(jobs))
	for _, j := range jobs {
		wg.Add(1)
		sem <- struct{}{}
		go func(j job) {
			defer wg.Done()
			defer func() { <-sem }()
			if err := fetchRaw(ctx, tdx, j.url, j.name, landingCycle, fullReland); err != nil {
				failures <- err
			}
		}(j)
	}
	wg.Wait()
	close(failures)
	joined := make([]error, 0, len(failures))
	for err := range failures {
		joined = append(joined, err)
	}
	// Only a full run touches every partition, so only a full run can tell a
	// partition nobody fetches from one this subset simply did not cover.
	if len(only) == 0 && raw.DB != nil {
		raw.ReportStalePartitions(ctx, raw.DB)
	}
	zap.S().Infow("end", "component", "ingest", "action", "raw", "event", "end", "scope", scope)
	return errors.Join(joined...)
}

func fetchRaw(ctx context.Context, tdx rawFetcher, url, name, landingCycle string, forceReland bool) error {
	return fetchRawWithVerifier(ctx, tdx, url, name, landingCycle, forceReland, raw.VerifyAndTouchLanding)
}

type rawLandingVerifier func(context.Context, raw.Target, string, string) error

func fetchRawWithVerifier(
	ctx context.Context,
	tdx rawFetcher,
	url, name, landingCycle string,
	forceReland bool,
	verify rawLandingVerifier,
) error {
	if landingCycle == "" {
		return errors.New("fetch raw: empty landing cycle")
	}
	target, mapped := raw.DumpTarget(url)
	for attempt := range 2 {
		result, err := tdx.GetInto(ctx, url, name, func(commit shared.TDXIntoCommit) error {
			if !mapped {
				return nil
			}
			return raw.DumpReader(ctx, target, commit.Marker, landingCycle, commit.Body)
		})
		if err != nil {
			return _oops.With("url", url).Wrapf(err, "fetch raw")
		}
		if result.Modified {
			return nil
		}
		if !mapped {
			zap.S().Warnw("skip", "component", "ingest", "url", url, "event", "skip", "reason", "not_modified")
			return nil
		}
		if forceReland && attempt == 0 {
			if result.Invalidate == nil {
				return _oops.With("url", url).Errorf("force reland: nil marker invalidator")
			}
			if err := result.Invalidate(); err != nil {
				return _oops.With("url", url).Wrapf(err, "force reland")
			}
			zap.S().Infow("refetch", "component", "ingest", "url", url, "event", "refetch", "reason", "full_reland")
			continue
		}

		err = verify(ctx, target, result.Marker, landingCycle)
		if err == nil {
			zap.S().Warnw("skip", "component", "ingest", "url", url, "event", "skip", "reason", "not_modified")
			return nil
		}
		if !errors.Is(err, raw.ErrLandingStateMismatch) {
			return _oops.With("url", url).Wrapf(err, "verify raw")
		}
		if attempt == 1 {
			return _oops.With("url", url).Wrapf(err, "verify raw after forced refetch")
		}
		if result.Invalidate == nil {
			return _oops.With("url", url).Wrapf(err, "verify raw: nil marker invalidator")
		}
		if invalidateErr := result.Invalidate(); invalidateErr != nil {
			return _oops.With("url", url).Wrapf(errors.Join(err, invalidateErr), "verify raw")
		}
		zap.S().Infow("refetch",
			"component", "ingest",
			"url", url,
			"event", "refetch",
			"reason", "landing_state_mismatch",
		)
	}
	return nil
}
