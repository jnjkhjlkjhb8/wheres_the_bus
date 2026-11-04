package maas

import (
	"context"
	"strconv"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
)

// railShapeCache keeps clipped stop-to-stop rail shapes. Each clip merges
// every rail_shapes line of its mode in Postgres (~40ms; TRA alone is 65k
// points), a plan clips once per station hop (~45 per plan), and a load test
// spent 99% of Postgres time here. Hops repeat across plans and rail_shapes
// only changes on the nightly load. Only successful clips are kept, so a
// failed query is retried next time instead of pinning the straight-line
// fallback.
type railShapeCache struct {
	entries *cache.TTLCache
}

const (
	_railShapeCacheTTL     = 6 * time.Hour
	_railShapeCacheEntries = 20000
)

func newRailShapeCache() *railShapeCache {
	return &railShapeCache{entries: cache.NewBoundedTTLCache(_railShapeCacheEntries)}
}

// clip is clipRailShape with memoization; a nil cache clips uncached.
func (c *railShapeCache) clip(ctx context.Context, db maasDB, mode string, a, b transitStopPoint) ([]*pb.Location, bool) {
	if !c.cacheable(db, a, b) {
		return clipRailShape(ctx, db, mode, a, b)
	}
	wkt, ok := c.wkt(ctx, db, mode, a, b)
	if !ok {
		return nil, false
	}
	return railShapePoints(wkt, mode)
}

func (c *railShapeCache) cacheable(db maasDB, a, b transitStopPoint) bool {
	return c != nil && db != nil && transitEndpointsUsable(a, b)
}

func (c *railShapeCache) wkt(ctx context.Context, db maasDB, mode string, a, b transitStopPoint) (string, bool) {
	key := railShapeKey(mode, a, b)
	if cached, hit := c.entries.Get(key); hit {
		return string(cached), true
	}
	wkt, ok := railShapeWKT(ctx, db, mode, a, b)
	if !ok {
		return "", false
	}
	c.entries.Set(key, []byte(wkt), _railShapeCacheTTL)
	return wkt, true
}

// railShapeKey keeps full float precision: MOTIS reports a station at the
// same coordinates every time, and rounding could merge two nearby stops.
func railShapeKey(mode string, a, b transitStopPoint) string {
	f := func(v float64) string { return strconv.FormatFloat(v, 'g', -1, 64) }
	return mode + "|" + f(a.lat) + "," + f(a.lng) + "|" + f(b.lat) + "," + f(b.lng)
}
