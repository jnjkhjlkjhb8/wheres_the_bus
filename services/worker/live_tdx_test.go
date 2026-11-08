package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/robfig/cron/v3"
)

func TestTDXCredentialsSetNeedsBothValues(t *testing.T) {
	tests := []struct {
		name, id, secret string
		want             bool
	}{
		{name: "both set", id: "id", secret: "secret", want: true},
		{name: "only id", id: "id"},
		{name: "only secret", secret: "secret"},
		{name: "neither"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("TDX_CLIENT_ID", tt.id)
			t.Setenv("TDX_CLIENT_SECRET", tt.secret)
			if got := tdxCredentialsSet(); got != tt.want {
				t.Fatalf("tdxCredentialsSet() = %v, want %v", got, tt.want)
			}
		})
	}
}

func liveSpecKeys(specs []pipeline.LiveSpec) []string {
	keys := make([]string, 0, len(specs))
	for _, spec := range specs {
		keys = append(keys, spec.Key)
	}
	return keys
}

func TestRunnableLiveSpecsDropsTDXJobsWithoutCredentials(t *testing.T) {
	registry := liveRegistry(nil, nil)
	tests := []struct {
		name   string
		hasTDX bool
		want   []string
	}{
		{name: "with credentials", hasTDX: true, want: liveSpecKeys(registry)},
		{name: "without credentials", want: []string{"bus_fast", "mrt"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := liveSpecKeys(runnableLiveSpecs(registry, tt.hasTDX)); !slices.Equal(got, tt.want) {
				t.Fatalf("runnable live jobs = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestManualLiveJob(t *testing.T) {
	tests := []struct {
		name, job, id string
		want, errText string
	}{
		{name: "known job with credentials", job: "buseta", id: "id", want: "bus"},
		{name: "unknown job", job: "missing-job", id: "id", errText: "unknown job"},
		{name: "known job without credentials", job: "bikeeta", errText: "TDX credentials missing"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("TDX_CLIENT_ID", tt.id)
			t.Setenv("TDX_CLIENT_SECRET", tt.id)
			got, err := manualLiveJob(tt.job)
			if got != tt.want || (err == nil) != (tt.errText == "") || err != nil && !strings.Contains(err.Error(), tt.errText) {
				t.Fatalf("manualLiveJob(%q) = %q, %v; want %q, error containing %q", tt.job, got, err, tt.want, tt.errText)
			}
		})
	}
}

func TestRegisterLiveCronsSchedulesOnlyNonTDXJobsWithoutCredentials(t *testing.T) {
	t.Setenv("TDX_CLIENT_ID", "")
	t.Setenv("TDX_CLIENT_SECRET", "")
	r := cron.New(cron.WithSeconds())
	registerLiveCrons(r, nil, nil, nil, nil)
	// One entry per cadence: bus_fast (20s) and mrt (15s).
	if got := len(r.Entries()); got != 2 {
		t.Fatalf("scheduled live cadences = %d, want 2", got)
	}
}

// TestRunOnceRejectsTDXJobWithoutCredentials passes no TDX client or Redis: the
// run must fail before it reaches either.
func TestRunOnceRejectsTDXJobWithoutCredentials(t *testing.T) {
	t.Setenv("TDX_CLIENT_ID", "")
	t.Setenv("TDX_CLIENT_SECRET", "")
	if err := runOnce("traeta", nil, nil, nil); err == nil || !strings.Contains(err.Error(), "TDX credentials missing") {
		t.Fatalf("runOnce(traeta) = %v, want a missing-credentials error", err)
	}
}

// TestManualRunWithoutTDXCredentialsFailsThroughEntryPoint drives the real
// `functions run` entry point; it connects to Redis and PostgreSQL but fails
// before writing to either.
func TestManualRunWithoutTDXCredentialsFailsThroughEntryPoint(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" || os.Getenv("REDIS_ADDR") == "" {
		t.Skip("requires PostgreSQL and Redis")
	}
	for _, name := range []string{"TDX_CLIENT_ID", "TDX_CLIENT_SECRET", "SENTRY_DSN", "ARCHIVE_MYSQL_DSN"} {
		t.Setenv(name, "")
	}
	t.Setenv("HEALTH_FILE", filepath.Join(t.TempDir(), "healthy"))
	oldHealth := _health
	t.Cleanup(func() { _health = oldHealth })

	err := runWorker([]string{"functions", "run", "buseta"}, func() { t.Fatal("manual run waited for signal") })
	if err == nil || !strings.Contains(err.Error(), "TDX credentials missing") {
		t.Fatalf("runWorker(run buseta) = %v, want a missing-credentials error", err)
	}
}
