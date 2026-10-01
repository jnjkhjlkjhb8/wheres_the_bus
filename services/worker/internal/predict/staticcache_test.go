package predict

import (
	"sync"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
)

func TestBusStaticCacheObservesGenerationAcrossProcessInstances(t *testing.T) {
	// Two independent maps model loader/functions containers. The loader's local
	// invalidation cannot touch the reader, so only the shared durable generation
	// causes the reader to reject generation 1 after generation 2 commits.
	var loaderCache sync.Map
	var readerCache sync.Map
	now := time.Now()
	StoreStaticMapIn(&loaderCache, "TPE", []busmodel.StationMap{{StopUID: "loader"}}, "1", now)
	StoreStaticMapIn(&readerCache, "TPE", []busmodel.StationMap{{StopUID: "old"}}, "1", now)
	loaderCache.Delete("TPE")

	if stops, ok := CachedStaticMapFrom(&readerCache, "TPE", "1", now.Add(time.Minute)); !ok || stops[0].StopUID != "old" {
		t.Fatalf("generation 1 cache = %v/%v, want old hit", stops, ok)
	}
	if _, ok := CachedStaticMapFrom(&readerCache, "TPE", "2", now.Add(time.Minute)); ok {
		t.Fatal("reader reused generation 1 after durable generation advanced to 2")
	}
}

func TestBusStaticCacheRedisOutageFallsBackOnlyUntilTTL(t *testing.T) {
	var cache sync.Map
	now := time.Now()
	StoreStaticMapIn(&cache, "TPE", []busmodel.StationMap{{StopUID: "old"}}, "7", now)
	if _, ok := CachedStaticMapFrom(&cache, "TPE", "", now.Add(_busStaticMapCacheTTL-time.Second)); !ok {
		t.Fatal("Redis outage should allow the bounded local fallback before TTL")
	}
	if _, ok := CachedStaticMapFrom(&cache, "TPE", "", now.Add(_busStaticMapCacheTTL)); ok {
		t.Fatal("Redis outage allowed stale cache at/after TTL")
	}
}

func TestStopOffsetCacheRemembersMisses(t *testing.T) {
	var cache sync.Map
	now := time.Now()

	out := map[StopOffsetKey]int{}
	missing := cachedStopOffsets(&cache, []string{"A", "B"}, now, out)
	if len(missing) != 2 {
		t.Fatalf("cold missing = %v, want both", missing)
	}

	// A returned one stop; B returned nothing but was still queried.
	storeStopOffsets(&cache, map[string][]stopOffset{
		"A": {{Direction: 0, StopUID: "S1", secs: 42}},
		"B": nil,
	}, now)

	out = map[StopOffsetKey]int{}
	if missing := cachedStopOffsets(&cache, []string{"A", "B"}, now, out); missing != nil {
		t.Errorf("warm missing = %v, want none: the empty result must be cached too", missing)
	}
	if got := out[StopOffsetKey{SubRouteUID: "A", Direction: 0, StopUID: "S1"}]; got != 42 {
		t.Errorf("A/S1 = %d, want 42", got)
	}
	if len(out) != 1 {
		t.Errorf("out = %v, want only A's stop", out)
	}

	out = map[StopOffsetKey]int{}
	if missing := cachedStopOffsets(&cache, []string{"A", "B"}, now.Add(_stopOffsetCacheTTL), out); len(missing) != 2 {
		t.Errorf("expired missing = %v, want both re-queried at TTL", missing)
	}
}
