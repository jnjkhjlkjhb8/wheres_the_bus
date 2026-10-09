package marker

import (
	"context"
	"errors"
	"testing"
	"time"
)

// fakeMarkerReader reports the marker present starting from readyAfter calls,
// returning err for the first errUntil calls (errUntil == 0 with a non-nil err
// means every call errors); it also records every job/date it was asked about.
type fakeMarkerReader struct {
	readyAfter int
	errUntil   int
	calls      int
	err        error
	gotJob     string
	gotDate    time.Time
}

func (f *fakeMarkerReader) MarkerExists(_ context.Context, job string, runDate time.Time) (bool, error) {
	f.calls++
	f.gotJob = job
	f.gotDate = runDate
	if f.err != nil && (f.errUntil == 0 || f.calls <= f.errUntil) {
		return false, f.err
	}
	return f.calls >= f.readyAfter, nil
}

// fakeClock advances by one interval step each time now() is read, letting
// tests control elapsed time without real waits.
type fakeClock struct {
	t    time.Time
	step time.Duration
}

func (c *fakeClock) now() time.Time {
	current := c.t
	c.t = c.t.Add(c.step)
	return current
}

func noopSleep(context.Context, time.Duration) error { return nil }

func TestWaitForPipelineMarkerReturnsImmediatelyWhenReady(t *testing.T) {
	reader := &fakeMarkerReader{readyAfter: 1}
	clock := &fakeClock{t: time.Unix(0, 0)}
	runDate := time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC)

	err := Wait(context.Background(), reader, "load", runDate,
		time.Minute, time.Hour, clock.now, noopSleep)
	if err != nil {
		t.Fatalf("Wait() error = %v, want nil", err)
	}
	if reader.calls != 1 {
		t.Fatalf("MarkerExists calls = %d, want 1 (no polling once ready)", reader.calls)
	}
	if reader.gotJob != "load" || !reader.gotDate.Equal(runDate) {
		t.Fatalf("MarkerExists called with job=%q date=%v, want job=load date=%v", reader.gotJob, reader.gotDate, runDate)
	}
}

func TestWaitForPipelineMarkerPollsUntilReady(t *testing.T) {
	reader := &fakeMarkerReader{readyAfter: 3}
	clock := &fakeClock{t: time.Unix(0, 0), step: time.Minute}
	sleeps := 0
	sleep := func(context.Context, time.Duration) error {
		sleeps++
		return nil
	}

	err := Wait(context.Background(), reader, "changetovector",
		time.Now(), 5*time.Minute, time.Hour, clock.now, sleep)
	if err != nil {
		t.Fatalf("Wait() error = %v, want nil", err)
	}
	if reader.calls != 3 {
		t.Fatalf("MarkerExists calls = %d, want 3", reader.calls)
	}
	if sleeps != 2 {
		t.Fatalf("sleep calls = %d, want 2 (one between each unready check)", sleeps)
	}
}

func TestWaitForPipelineMarkerGivesUpAtDeadline(t *testing.T) {
	reader := &fakeMarkerReader{readyAfter: 1000} // never ready within the test
	start := time.Unix(0, 0)
	// now() is read once to set the deadline, then once per check: 45-minute
	// steps put the deadline check past 2 hours after the third poll.
	clock := &fakeClock{t: start, step: 45 * time.Minute}

	err := Wait(context.Background(), reader, "load", time.Now(),
		5*time.Minute, 2*time.Hour, clock.now, noopSleep)
	if err == nil {
		t.Fatal("Wait() error = nil, want deadline error")
	}
	if reader.calls != 3 {
		t.Fatalf("MarkerExists calls = %d, want 3 before giving up", reader.calls)
	}
}

func TestWaitForPipelineMarkerKeepsPollingOnReaderError(t *testing.T) {
	readErr := errors.New("db unavailable")
	reader := &fakeMarkerReader{err: readErr}
	clock := &fakeClock{t: time.Unix(0, 0), step: 45 * time.Minute}
	sleeps := 0
	sleep := func(context.Context, time.Duration) error {
		sleeps++
		return nil
	}

	err := Wait(context.Background(), reader, "load", time.Now(),
		5*time.Minute, 2*time.Hour, clock.now, sleep)
	if !errors.Is(err, readErr) {
		t.Fatalf("Wait() error = %v, want deadline error wrapping %v", err, readErr)
	}
	if reader.calls < 2 {
		t.Fatalf("MarkerExists calls = %d, want repeated polling despite read errors", reader.calls)
	}
	if sleeps != reader.calls-1 {
		t.Fatalf("sleep calls = %d, want %d (one between each errored check)", sleeps, reader.calls-1)
	}
}

func TestWaitForPipelineMarkerRecoversFromTransientReaderError(t *testing.T) {
	reader := &fakeMarkerReader{readyAfter: 2, errUntil: 1, err: errors.New("blip")}
	clock := &fakeClock{t: time.Unix(0, 0), step: time.Minute}

	err := Wait(context.Background(), reader, "load", time.Now(),
		5*time.Minute, 2*time.Hour, clock.now, noopSleep)
	if err != nil {
		t.Fatalf("Wait() error = %v, want nil after transient read error", err)
	}
	if reader.calls != 2 {
		t.Fatalf("MarkerExists calls = %d, want 2 (one errored, one ready)", reader.calls)
	}
}

func TestWaitForPipelineMarkerPropagatesSleepError(t *testing.T) {
	reader := &fakeMarkerReader{readyAfter: 5}
	clock := &fakeClock{t: time.Unix(0, 0)}
	wantErr := context.Canceled
	sleep := func(context.Context, time.Duration) error { return wantErr }

	err := Wait(context.Background(), reader, "load", time.Now(),
		time.Minute, time.Hour, clock.now, sleep)
	if !errors.Is(err, wantErr) {
		t.Fatalf("Wait() error = %v, want %v", err, wantErr)
	}
}
