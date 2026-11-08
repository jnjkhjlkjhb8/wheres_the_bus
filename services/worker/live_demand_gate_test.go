package main

import (
	"context"
	"errors"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestRunLiveIsolatesFailingSpec(t *testing.T) {
	// One spec whose run returns an error (or panics) must not prevent the others
	// from running: runLive isolates each job.
	var ran []string
	specs := []pipeline.LiveSpec{
		{Key: "ok1", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			ran = append(ran, "ok1")
			return nil
		}},
		{Key: "boom", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			return errors.New("boom")
		}},
		{Key: "panic", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			panic("kaboom")
		}},
		{Key: "ok2", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			ran = append(ran, "ok2")
			return nil
		}},
	}
	pipeline.RunLive(context.Background(), &fakeLiveSource{}, &captureLiveSink{}, specs, nil)
	if len(ran) != 2 || ran[0] != "ok1" || ran[1] != "ok2" {
		t.Fatalf("healthy specs ran = %v, want [ok1 ok2]", ran)
	}
}

func TestRunLiveFiltersByKey(t *testing.T) {
	// A non-empty keys slice runs only the matching specs.
	var ran []string
	specs := []pipeline.LiveSpec{
		{Key: "a", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			ran = append(ran, "a")
			return nil
		}},
		{Key: "b", Run: func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error {
			ran = append(ran, "b")
			return nil
		}},
	}
	pipeline.RunLive(context.Background(), &fakeLiveSource{}, &captureLiveSink{}, specs, []string{"b"})
	if len(ran) != 1 || ran[0] != "b" {
		t.Fatalf("ran = %v, want [b]", ran)
	}
}

// TestLiveDemandGateNeverFetchesAnUnwatchedCity: without demand a city is
// skipped on every tick and nothing is written for it, so its live keys
// expire instead of being polled on a slower cadence.
func TestLiveDemandGateNeverFetchesAnUnwatchedCity(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	ctx := context.Background()

	sink := &captureLiveSink{}
	for range 10 {
		if pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
			t.Fatal("unwatched city was let through")
		}
	}
	if len(sink.sets) != 0 || len(sink.expires) != 0 || len(sink.refresh) != 0 {
		t.Fatalf("gate wrote for an unwatched city: sets=%v expires=%v refresh=%v", sink.sets, sink.expires, sink.refresh)
	}

	watched := &captureLiveSink{
		strings: map[string]string{shared.LiveDemandKey("bus_eta", "YilanCounty"): "1"},
	}
	for range 10 {
		if !pipeline.LiveDemandGate(ctx, watched, "bus_eta", "YilanCounty") {
			t.Fatal("watched city was skipped")
		}
	}
	// Demand is per dataset: watching buses in a city does not fetch its bikes.
	if pipeline.LiveDemandGate(ctx, watched, "bike", "YilanCounty") {
		t.Fatal("bus_eta demand opened the bike gate")
	}
}

// TestLiveDemandGateFetchesWhenRedisFails proves the gate degrades to polling
// rather than to silence: a Redis read failure must not be read as "nobody is
// watching", which would stall every city at once.
func TestLiveDemandGateFetchesWhenRedisFails(t *testing.T) {
	sink := &errStringLiveSink{captureLiveSink: &captureLiveSink{}, err: errors.New("redis down")}
	if !pipeline.LiveDemandGate(context.Background(), sink, "bus_eta", "YilanCounty") {
		t.Fatal("gate skipped the city on a Redis read failure")
	}
}

// errStringLiveSink is a captureLiveSink whose reads always fail.
type errStringLiveSink struct {
	*captureLiveSink
	err error
}

func (s *errStringLiveSink) GetString(context.Context, string) (string, error) {
	return "", s.err
}
