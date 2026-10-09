package predict

import (
	"sync"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
)

// _busStaticMapCache holds each city prefix's station map in memory so the 30s
// bus ETA cron does not re-query PostgreSQL every tick. A committed city rebuild
// invalidates its prefix locally and advances the durable Redis generation.
var _busStaticMapCache sync.Map

const _busStaticMapCacheTTL = 5 * time.Minute

type busStaticMapCacheEntry struct {
	stops      []busmodel.StationMap
	generation string
	loadedAt   time.Time
}

func CachedStaticMapFrom(cache *sync.Map, prefix, generation string, now time.Time) ([]busmodel.StationMap, bool) {
	v, ok := cache.Load(prefix)
	if !ok {
		return nil, false
	}
	entry, ok := v.(busStaticMapCacheEntry)
	if !ok || now.Sub(entry.loadedAt) >= _busStaticMapCacheTTL {
		cache.Delete(prefix)
		return nil, false
	}
	// A non-empty durable generation is authoritative. During a Redis outage
	// generation is empty; the bounded TTL is the fallback that prevents an
	// offline worker from retaining yesterday's map indefinitely.
	if generation != "" && entry.generation != generation {
		cache.Delete(prefix)
		return nil, false
	}
	return entry.stops, true
}

// storeBusStaticMap caches a city prefix's station map for reuse by later ETA ticks.
func StoreStaticMap(prefix string, list []busmodel.StationMap) {
	StoreStaticMapIn(&_busStaticMapCache, prefix, list, "", time.Now())
}

func StoreStaticMapIn(cache *sync.Map, prefix string, list []busmodel.StationMap, generation string, now time.Time) {
	cache.Store(prefix, busStaticMapCacheEntry{stops: list, generation: generation, loadedAt: now})
}

// InvalidateStaticMap clears all maps for tests/process teardown. Production
// commits use InvalidateStaticMapCity to avoid evicting unrelated cities.
func InvalidateStaticMap() {
	_busStaticMapCache.Range(func(key, _ any) bool {
		_busStaticMapCache.Delete(key)
		return true
	})
}

func InvalidateStaticMapCity(prefix string) {
	_busStaticMapCache.Delete(prefix)
}

var _stopOffsetCache sync.Map

const _stopOffsetCacheTTL = time.Hour

type stopOffset struct {
	Direction int32
	StopUID   string
	secs      int
}

type stopOffsetCacheEntry struct {
	offsets  []stopOffset
	loadedAt time.Time
}

// cachedStopOffsets fills out from the cache and returns the uids that missed.
func cachedStopOffsets(cache *sync.Map, uids []string, now time.Time, out map[StopOffsetKey]int) []string {
	var missing []string
	for _, uid := range uids {
		v, ok := cache.Load(uid)
		entry, typed := v.(stopOffsetCacheEntry)
		if !ok || !typed || now.Sub(entry.loadedAt) >= _stopOffsetCacheTTL {
			cache.Delete(uid)
			missing = append(missing, uid)
			continue
		}
		for _, o := range entry.offsets {
			out[StopOffsetKey{SubRouteUID: uid, Direction: o.Direction, StopUID: o.StopUID}] = o.secs
		}
	}
	return missing
}

func storeStopOffsets(cache *sync.Map, fetched map[string][]stopOffset, now time.Time) {
	for uid, offsets := range fetched {
		cache.Store(uid, stopOffsetCacheEntry{offsets: offsets, loadedAt: now})
	}
}

// StaticMapCache is the process-wide station-map cache the bus ETA tick reads
// and the loader invalidates.
func StaticMapCache() *sync.Map { return &_busStaticMapCache }
