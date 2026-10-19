package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
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

func hasTDXCredentials() bool {
	return os.Getenv("TDX_CLIENT_ID") != "" && os.Getenv("TDX_CLIENT_SECRET") != ""
}

func ingestRaw(ctx context.Context, tdx rawFetcher, tables ...string) error {
	if !hasTDXCredentials() {
		zap.S().Infow("idle", "component", "ingest", "action", "raw", "event", "idle", "reason", "no_credentials")
		return nil
	}

	scope, only := rawIngestSelection(tables)
	fullReland := fullRawReland(only, time.Now().In(pipeline.Taipei))
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

	jobs := rawIngestJobs(only)
	joined := runRawIngestJobs(ctx, tdx, jobs, landingCycle, fullReland)

	// Only a full run touches every partition, so only a full run can tell a
	// partition nobody fetches from one this subset simply did not cover.
	reportFullRawIngest(ctx, only)
	zap.S().Infow("end", "component", "ingest", "action", "raw", "event", "end", "scope", scope)
	return errors.Join(joined...)
}

func rawIngestSelection(tables []string) (string, map[string]bool) {
	only := make(map[string]bool, len(tables))
	for _, table := range tables {
		only[table] = true
	}
	if len(tables) == 0 {
		return "all", only
	}
	return strings.Join(tables, ","), only
}

func fullRawReland(only map[string]bool, now time.Time) bool {
	return len(only) == 0 && now.Weekday() == _fullRelandWeekday
}

func reportFullRawIngest(ctx context.Context, only map[string]bool) {
	// Subset runs cannot establish freshness for partitions they did not fetch.
	if len(only) == 0 && raw.DB != nil {
		raw.ReportStalePartitions(ctx, raw.DB)
	}
}

type rawIngestJob struct{ url, name string }

func rawIngestJobs(only map[string]bool) []rawIngestJob {
	var jobs []rawIngestJob
	for _, d := range dataset.Registry() {
		if !selectedRawDataset(d, only) {
			continue
		}
		for _, part := range d.Partitions() {
			jobs = append(jobs, rawIngestJob{d.URL(part), d.Name(part)})
		}
	}

	return jobs
}
func selectedRawDataset(d dataset.Spec, only map[string]bool) bool {
	if !d.Fetched() {
		return false
	}
	return len(only) == 0 || only[d.RawTable]
}

func runRawIngestJobs(ctx context.Context, tdx rawFetcher, jobs []rawIngestJob, landingCycle string, fullReland bool) []error {
	sem := make(chan struct{}, 3)
	var wg sync.WaitGroup
	failures := make(chan error, len(jobs))
	for _, j := range jobs {
		wg.Add(1)
		sem <- struct{}{}
		go func(j rawIngestJob) {
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
	return joined
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
	return fetchRawAttempts(ctx, tdx, url, name, landingCycle, forceReland, verify)
}

func fetchRawAttempts(ctx context.Context, tdx rawFetcher, url, name, landingCycle string, forceReland bool, verify rawLandingVerifier) error {
	retry, err := fetchRawAttempt(ctx, tdx, url, name, landingCycle, forceReland, verify, 0)
	if err != nil || !retry {
		return err
	}
	_, err = fetchRawAttempt(ctx, tdx, url, name, landingCycle, forceReland, verify, 1)
	return err
}

func fetchRawAttempt(ctx context.Context, tdx rawFetcher, url, name, landingCycle string, forceReland bool, verify rawLandingVerifier, attempt int) (bool, error) {
	target, mapped := raw.DumpTarget(url)
	result, err := tdx.GetInto(ctx, url, name, rawLandingCommitter(ctx, mapped, target, landingCycle))
	if err != nil {
		return false, _oops.With("url", url).Wrapf(err, "fetch raw")
	}
	return processRawFetchResult(ctx, target, mapped, result, url, landingCycle, forceReland, verify, attempt)
}

func processRawFetchResult(ctx context.Context, target raw.Target, mapped bool, result shared.TDXIntoResult, url, landingCycle string, forceReland bool, verify rawLandingVerifier, attempt int) (bool, error) {
	if result.Modified {
		return false, nil
	}
	if !mapped {
		zap.S().Warnw("skip", "component", "ingest", "url", url, "event", "skip", "reason", "not_modified")
		return false, nil
	}
	return processNotModifiedRaw(ctx, verify, target, result, url, landingCycle, forceReland, attempt)
}

func processNotModifiedRaw(ctx context.Context, verify rawLandingVerifier, target raw.Target, result shared.TDXIntoResult, url, landingCycle string, forceReland bool, attempt int) (bool, error) {
	if shouldForceRawReland(forceReland, attempt) {
		return true, forceRawReland(result, url)
	}

	err := verify(ctx, target, result.Marker, landingCycle)
	if err == nil {
		zap.S().Warnw("skip", "component", "ingest", "url", url, "event", "skip", "reason", "not_modified")
		return false, nil
	}
	return handleRawVerificationFailure(result, url, err, attempt)
}

func shouldForceRawReland(forceReland bool, attempt int) bool {
	return forceReland && attempt == 0
}

func handleRawVerificationFailure(result shared.TDXIntoResult, url string, err error, attempt int) (bool, error) {
	if !errors.Is(err, raw.ErrLandingStateMismatch) {
		return false, _oops.With("url", url).Wrapf(err, "verify raw")
	}
	if attempt == 1 {
		return false, _oops.With("url", url).Wrapf(err, "verify raw after forced refetch")
	}
	return true, invalidateMismatchedRaw(result, url, err)
}
func forceRawReland(result shared.TDXIntoResult, url string) error {
	if result.Invalidate == nil {
		return _oops.With("url", url).Errorf("force reland: nil marker invalidator")
	}
	if err := result.Invalidate(); err != nil {
		return _oops.With("url", url).Wrapf(err, "force reland")
	}
	zap.S().Infow("refetch", "component", "ingest", "url", url, "event", "refetch", "reason", "full_reland")
	return nil
}
func invalidateMismatchedRaw(result shared.TDXIntoResult, url string, err error) error {
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
	return nil
}

func rawLandingCommitter(ctx context.Context, mapped bool, target raw.Target, landingCycle string) func(shared.TDXIntoCommit) error {
	return func(commit shared.TDXIntoCommit) error {
		if !mapped {
			return nil
		}
		return raw.DumpReader(ctx, target, commit.Marker, landingCycle, commit.Body)
	}
}
