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

func TestLiveDemandGateSkipsUnwatchedCityUntilColdCadence(t *testing.T) {
	ctx := context.Background()

	sink := &captureLiveSink{}
	fetched := 0
	for range 10 {
		if pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
			fetched++
		}
	}
	if fetched != 1 {
		t.Fatalf("unwatched city fetched %d times across 10 ticks, want 1", fetched)
	}
	coldKey := shared.LiveColdKey("bus_eta", "YilanCounty")
	if got := sink.strings[coldKey]; got == "" {
		t.Fatalf("cold marker %q not written", coldKey)
	}
	for _, write := range sink.sets {
		if write.key == coldKey && write.ttl != pipeline.LiveColdCadence {
			t.Fatalf("cold marker TTL = %v, want %v", write.ttl, pipeline.LiveColdCadence)
		}
	}

	// The marker expiring is what lets the next fetch through; the fake has no
	// clock, so dropping the key is how a tick past the cadence is expressed.
	delete(sink.strings, coldKey)
	if !pipeline.LiveDemandGate(ctx, sink, "bus_eta", "YilanCounty") {
		t.Fatal("expired cold marker did not release the next fetch")
	}

	watched := &captureLiveSink{
		strings: map[string]string{shared.LiveDemandKey("bus_eta", "YilanCounty"): "1"},
	}
	for range 10 {
		if !pipeline.LiveDemandGate(ctx, watched, "bus_eta", "YilanCounty") {
			t.Fatal("watched city was skipped")
		}
	}
	if len(watched.sets) != 0 {
		t.Fatalf("watched city wrote %d cold markers, want 0", len(watched.sets))
	}

	// A city gated under one dataset must not silence the other: the two jobs
	// poll independently and share nothing but the city name.
	if !pipeline.LiveDemandGate(ctx, sink, "bike", "YilanCounty") {
		t.Fatal("bike was gated by the bus_eta cold marker")
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
