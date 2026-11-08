package main

import (
	"context"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

// wakeSource records every fetch name and answers each with a 304.
type wakeSource struct {
	mu    sync.Mutex
	names []string
}

func (s *wakeSource) Fetch(_ context.Context, _, name string) (*shared.TDXFetch, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.names = append(s.names, name)
	return &shared.TDXFetch{Modified: false}, nil
}

func (s *wakeSource) fetched() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.names)
}

// wakeDemandSink holds demand for every partition the wake tests name, so
// only the wake decides what runs.
func wakeDemandSink() *captureLiveSink {
	sink := &captureLiveSink{strings: map[string]string{}}
	for _, key := range []string{
		shared.LiveDemandKey("bus_eta", "Tainan"), shared.LiveDemandKey("bus_eta", "Kaohsiung"),
		shared.LiveDemandKey("bus_eta", "Taipei"), shared.LiveDemandKey("bus_eta", "NewTaipei"),
		shared.LiveDemandKey("bike", "Taichung"), shared.LiveDemandKey("bike", "Kaohsiung"),
		shared.LiveDemandKey("tra", "TRA"), shared.LiveDemandKey("thsr_seats", "THSR"),
	} {
		sink.strings[key] = "1"
	}
	return sink
}

func testWaker(hasTDX bool, src pipeline.LiveSource, sink pipeline.LiveSink) *liveWaker {
	guard := pipeline.NewLiveFetchGuard()
	specs := runnableLiveSpecs(liveRegistry(nil, nil, guard), hasTDX)
	return newLiveWaker(src, sink, specs, liveWakeTargets(nil, nil, guard))
}

// seedWakeStops serves each city's stops from the static cache, so a bus run
// reaches its fetch without a database.
func seedWakeStops(t *testing.T, cities ...string) {
	t.Helper()
	for _, city := range cities {
		prefix := busmodel.CityPrefix[city]
		predict.StoreStaticMapIn(predict.StaticMapCache(), prefix, []busmodel.StationMap{{SubRouteUID: prefix + "1", StopUID: "S1"}}, "", time.Now())
		t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
	}
}

func TestLiveWakeRunsExactlyTheWokenPartition(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	seedWakeStops(t, "Tainan", "Kaohsiung", "Taipei", "NewTaipei")
	for _, tc := range []struct {
		key  string
		want func([]string) bool
	}{
		{shared.LiveDemandKey("bus_eta", "Tainan"), func(names []string) bool {
			return slices.Contains(names, "bus_EstimatedTimeOfArrivalTainan") &&
				!slices.ContainsFunc(names, func(name string) bool { return !strings.HasSuffix(name, "Tainan") })
		}},
		{shared.LiveDemandKey("bike", "Taichung"), func(names []string) bool {
			return slices.Equal(names, []string{"bike_availabilityTaichung"})
		}},
		{shared.LiveDemandKey("tra", "TRA"), func(names []string) bool { return slices.Equal(names, []string{"tra_delay"}) }},
		{shared.LiveDemandKey("thsr_seats", "THSR"), func(names []string) bool {
			return slices.Equal(names, []string{"thsr_availableseats"})
		}},
	} {
		src := &wakeSource{}
		testWaker(true, src, wakeDemandSink()).wake(tc.key)
		if got := src.fetched(); !tc.want(got) {
			t.Fatalf("wake %s fetched %v", tc.key, got)
		}
	}
}

// TestLiveWakeIgnoresKeysThatMustNotFetch: Taipei and New Taipei buses come
// from Data.taipei, and a key no scheduled job owns is only logged.
func TestLiveWakeIgnoresKeysThatMustNotFetch(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	core, logs := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	seedWakeStops(t, "Taipei", "NewTaipei")
	src := &wakeSource{}
	waker := testWaker(true, src, wakeDemandSink())
	for _, key := range []string{
		shared.LiveDemandKey("bus_eta", "Taipei"), shared.LiveDemandKey("bus_eta", "NewTaipei"),
		shared.LiveDemandKey("mrt", "Taipei"), shared.LiveDemandKey("ferry", "Penghu"),
		"live:demand:tra", "garbage",
	} {
		waker.wake(key)
	}
	if got := src.fetched(); len(got) != 0 {
		t.Fatalf("ignored wakes fetched %v", got)
	}
	// Only the four keys no scheduled job owns are ignored outright; the bus
	// job itself turns the Data.taipei cities away.
	if ignored, panics := logs.FilterMessage("ignored").Len(), logs.FilterMessage("panic").Len(); ignored != 4 || panics != 0 {
		t.Fatalf("ignored=%d panics=%d", ignored, panics)
	}
}

func TestLiveWakeWithoutTDXCredentialsRunsNothing(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	seedWakeStops(t, "Tainan")
	src := &wakeSource{}
	waker := testWaker(false, src, wakeDemandSink())
	for _, key := range []string{
		shared.LiveDemandKey("bus_eta", "Tainan"), shared.LiveDemandKey("bike", "Taichung"),
		shared.LiveDemandKey("tra", "TRA"), shared.LiveDemandKey("thsr_seats", "THSR"),
	} {
		waker.wake(key)
	}
	if got := src.fetched(); len(got) != 0 {
		t.Fatalf("wakes without TDX fetched %v", got)
	}
}

// TestLiveWakeAndTickFetchACityOnce: the cron tick right after a wake shares
// its guard and leaves the woken city alone.
func TestLiveWakeAndTickFetchACityOnce(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	seedWakeStops(t, "Tainan")
	src := &wakeSource{}
	sink := &captureLiveSink{strings: map[string]string{shared.LiveDemandKey("bus_eta", "Tainan"): "1"}}
	waker := testWaker(true, src, sink)
	waker.wake(shared.LiveDemandKey("bus_eta", "Tainan"))
	pipeline.RunLiveSpec(context.Background(), src, sink, waker.specs["bus"])
	etas := 0
	for _, name := range src.fetched() {
		if name == "bus_EstimatedTimeOfArrivalTainan" {
			etas++
		}
	}
	if etas != 1 {
		t.Fatalf("Tainan ETA fetched %d times: %v", etas, src.fetched())
	}
}

// probeWaker wakes a single "probe" job whose run reports what it was given.
func probeWaker(run func(ctx context.Context, partition string)) *liveWaker {
	specs := []pipeline.LiveSpec{{Key: "probe", Cadence: "@every 30s"}}
	targets := map[string]liveWakeTarget{"probe": {spec: "probe", run: func(partition string) liveRun {
		return func(ctx context.Context, _ pipeline.BoundFetch, _ pipeline.LiveSink) error {
			run(ctx, partition)
			return nil
		}
	}}}
	return newLiveWaker(&wakeSource{}, &captureLiveSink{}, specs, targets)
}

func TestLiveWakeKeepsTickDeadlineAndRecoversPanic(t *testing.T) {
	var remaining time.Duration
	var partition string
	waker := probeWaker(func(ctx context.Context, got string) {
		deadline, _ := ctx.Deadline()
		remaining, partition = time.Until(deadline), got
		panic("probe failed")
	})
	waker.wake(shared.LiveDemandKey("probe", "P1"))
	want := liveTickDeadline("@every 30s")
	if partition != "P1" || remaining <= want-time.Second || remaining > want {
		t.Fatalf("partition=%q remaining=%v, want P1 within %v", partition, remaining, want)
	}
}

func TestLiveWakeListenRunsPublishedWakesUntilStopped(t *testing.T) {
	addr := os.Getenv("REDIS_ADDR")
	if addr == "" {
		t.Skip("REDIS_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = rc.Close() })
	core, logs := observer.New(zap.InfoLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	got := make(chan string, 16)
	waker := probeWaker(func(_ context.Context, partition string) { got <- partition })
	stop := waker.listen(rc)
	key := shared.LiveDemandKey("probe", t.Name())
	deadline := time.After(10 * time.Second)
	// The subscription may not be live yet, so publish until a wake arrives.
	for received := false; !received; {
		rc.Publish(t.Context(), shared.LiveWakeChannel, key)
		select {
		case partition := <-got:
			if partition != t.Name() {
				t.Fatalf("woke partition %q", partition)
			}
			received = true
		case <-time.After(100 * time.Millisecond):
		case <-deadline:
			t.Fatal("published wake never ran")
		}
	}
	stop()
	waker.runs.Wait()
	if logs.FilterMessage("close failed").Len() != 0 {
		t.Fatal("a clean stop reported a close failure")
	}
}
