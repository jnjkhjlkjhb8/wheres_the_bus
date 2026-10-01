package nearby

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sync"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

const (
	_defaultNearbyRadius = 670
	_maxNearbyRadius     = 5000
	_defaultNearbyLimit  = 80
	// Radii are snapped up to this many metres so viewport-derived values share
	// cache entries; _maxNearbyRadius is a multiple of it, so snapping can never
	// push a valid radius past the maximum.
	_nearbyRadiusBucket = 100
)

const (
	// Station positions only change at the 03:30 load, so the bound here is
	// staleness tolerance rather than correctness.
	_nearbyCacheTTL = 10 * time.Minute
	// Keys are coordinate cells, so a panning client mints a new one per
	// settled camera position: the cache has to be capped or it grows without
	// bound inside the router's 230 MiB heap.
	_nearbyCacheMaxEntries = 128
	_nearbyRequestTimeout  = 3 * time.Second
	_nearbyConcurrency     = 8
)

var nearbyBudget = make(chan struct{}, _nearbyConcurrency)

var (
	ErrInvalidNearbyQuery = errors.New("invalid nearby query")
	ErrNearbyUnavailable  = errors.New("nearby discovery unavailable")
)

type GeoPoint struct {
	Lon float64
	Lat float64
}

type NearbyMode int32

const (
	NearbyBus NearbyMode = iota + 1
	_nearbyBike
	_nearbyMRT
	_nearbyTRA
	_nearbyTHSR
)

var AllNearbyModes = [...]NearbyMode{NearbyBus, _nearbyBike, _nearbyMRT, _nearbyTRA, _nearbyTHSR}

type NearbyQuery struct {
	Origin       GeoPoint
	RadiusMeters int
	Limit        int
}

type NearbyCandidate struct {
	Mode           NearbyMode
	ID             string
	Name           string
	City           string
	Point          GeoPoint
	GeodesicMeters float64
}

type WalkingMetric struct {
	DurationSeconds *float64
	DistanceMeters  *float64
}

type nearbyStore interface {
	Find(context.Context, NearbyMode, NearbyQuery) ([]NearbyCandidate, error)
}

type walkingRouter interface {
	RouteMany(context.Context, GeoPoint, []GeoPoint) ([]WalkingMetric, error)
}

type NearbyDiscovery struct {
	store  nearbyStore
	router walkingRouter

	cacheMu    sync.Mutex
	cache      *cache.TTLCache
	cacheCount int
}

func NewNearbyDiscovery(store nearbyStore, router walkingRouter) *NearbyDiscovery {
	return &NearbyDiscovery{store: store, router: router, cache: cache.NewTTLCache()}
}

type nearbyModeResult struct {
	mode       NearbyMode
	candidates []NearbyCandidate
	queryError error
}

// nearbyCacheKey rounds the origin to ~11 m, well inside GPS accuracy, so a
// re-query from the same spot reuses the previous walking-time computation.
func nearbyCacheKey(query NearbyQuery) string {
	return fmt.Sprintf("near:%.4f:%.4f:%d:%d",
		query.Origin.Lat, query.Origin.Lon, query.RadiusMeters, query.Limit)
}

func (d *NearbyDiscovery) cachedResponse(key string) (*pb.RespNear, bool) {
	d.cacheMu.Lock()
	cache := d.cache
	d.cacheMu.Unlock()
	if cache == nil {
		return nil, false
	}
	data, ok := cache.Get(key)
	if !ok {
		return nil, false
	}
	response := &pb.RespNear{}
	if err := proto.Unmarshal(data, response); err != nil {
		return nil, false
	}
	return response, true
}

// on overflow the whole map is dropped rather than evicted per key. Swap
// in an LRU only if the hit rate after a drop turns out to matter.
func (d *NearbyDiscovery) cacheResponse(key string, response *pb.RespNear) {
	data, err := proto.Marshal(response)
	if err != nil {
		return
	}
	d.cacheMu.Lock()
	defer d.cacheMu.Unlock()
	if d.cache == nil {
		return
	}
	if d.cacheCount >= _nearbyCacheMaxEntries {
		d.cache, d.cacheCount = cache.NewTTLCache(), 0
	}
	d.cacheCount++
	d.cache.Set(key, data, _nearbyCacheTTL)
}

func receiveNearbyModeResult(ctx context.Context, results <-chan nearbyModeResult) (nearbyModeResult, error) {
	select {
	case result := <-results:
		if err := ctx.Err(); err != nil {
			return nearbyModeResult{}, err
		}
		return result, nil
	case <-ctx.Done():
		return nearbyModeResult{}, ctx.Err()
	}
}

func validateNearbyQuery(query NearbyQuery) (NearbyQuery, error) {
	if math.IsNaN(query.Origin.Lon) || math.IsInf(query.Origin.Lon, 0) ||
		query.Origin.Lon < -180 || query.Origin.Lon > 180 {
		return NearbyQuery{}, _oops.Wrapf(ErrInvalidNearbyQuery, "longitude must be finite and between -180 and 180")
	}
	if math.IsNaN(query.Origin.Lat) || math.IsInf(query.Origin.Lat, 0) ||
		query.Origin.Lat < -90 || query.Origin.Lat > 90 {
		return NearbyQuery{}, _oops.Wrapf(ErrInvalidNearbyQuery, "latitude must be finite and between -90 and 90")
	}
	if query.RadiusMeters == 0 {
		query.RadiusMeters = _defaultNearbyRadius
	}
	if query.RadiusMeters < 0 || query.RadiusMeters > _maxNearbyRadius {
		return NearbyQuery{}, _oops.With("_max_nearby_radius", _maxNearbyRadius).Wrapf(ErrInvalidNearbyQuery, "radius must be zero or between 1 and metres")
	}
	if query.Limit <= 0 {
		query.Limit = _defaultNearbyLimit
	}
	query.RadiusMeters = (query.RadiusMeters + _nearbyRadiusBucket - 1) /
		_nearbyRadiusBucket * _nearbyRadiusBucket
	return query, nil
}

func (d *NearbyDiscovery) Discover(ctx context.Context, query NearbyQuery) (*pb.RespNear, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	query, err := validateNearbyQuery(query)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	cacheKey := nearbyCacheKey(query)
	if cached, ok := d.cachedResponse(cacheKey); ok {
		return cached, nil
	}

	workCtx, cancel := context.WithTimeout(ctx, _nearbyRequestTimeout)
	defer cancel()
	select {
	case nearbyBudget <- struct{}{}:
		defer func() { <-nearbyBudget }()
	case <-workCtx.Done():
		return nil, workCtx.Err()
	}
	candidates, err := d.findAll(workCtx, query)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	response, err := d.enrich(workCtx, query.Origin, candidates)
	if err != nil {
		return nil, err
	}
	d.cacheResponse(cacheKey, response)
	return response, nil
}

// findAll queries every mode concurrently and fails the whole request as soon
// as any single mode errors, so a partial nearby list never reaches the client.
func (d *NearbyDiscovery) findAll(ctx context.Context, query NearbyQuery) (map[NearbyMode][]NearbyCandidate, error) {
	workerCtx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	defer wg.Wait()
	defer cancel()

	results := make(chan nearbyModeResult, len(AllNearbyModes))
	for _, mode := range AllNearbyModes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			candidates, err := d.store.Find(workerCtx, mode, query)
			select {
			case results <- nearbyModeResult{mode: mode, candidates: candidates, queryError: err}:
			case <-workerCtx.Done():
			}
		}()
	}

	byMode := make(map[NearbyMode][]NearbyCandidate, len(AllNearbyModes))
	for range AllNearbyModes {
		result, err := receiveNearbyModeResult(ctx, results)
		if err != nil {
			return nil, err
		}
		if result.queryError != nil {
			if isContextError(result.queryError) {
				return nil, result.queryError
			}
			zap.S().Errorw("failed",
				"component", "near",
				"action", "query",
				"mode", result.mode,
				"event", "failed",
				"err", result.queryError,
			)
			cancel()
			return nil, ErrNearbyUnavailable
		}
		byMode[result.mode] = result.candidates
	}
	return byMode, nil
}

func (d *NearbyDiscovery) enrich(ctx context.Context, origin GeoPoint, byMode map[NearbyMode][]NearbyCandidate) (*pb.RespNear, error) {
	points := make([]GeoPoint, 0, len(byMode)*_defaultNearbyLimit)
	for _, mode := range AllNearbyModes {
		for _, item := range byMode[mode] {
			points = append(points, item.Point)
		}
	}

	var metrics []WalkingMetric
	var routeErr error
	if d.router != nil && len(points) > 0 {
		metrics, routeErr = d.router.RouteMany(ctx, origin, points)
	}
	if isContextError(routeErr) {
		return nil, routeErr
	}
	if routeErr != nil {
		zap.S().Errorw("failed",
			"component", "near",
			"action", "route",
			"event", "failed",
			"count", len(points),
			"err", routeErr,
		)
		metrics = nil
	}

	response := &pb.RespNear{NearBusStations: make(map[string]*pb.ArrayNear)}
	offset := 0
	for _, mode := range AllNearbyModes {
		candidates := byMode[mode]
		if len(candidates) == 0 {
			continue
		}
		if err := appendNearbyResult(response, mode, nearbyStations(candidates, metrics[min(offset, len(metrics)):])); err != nil {
			return nil, err
		}
		offset += len(candidates)
	}
	return response, nil
}

// nearbyStations pairs candidates with the leading window of metrics; a short
// or absent window falls back to the geodesic estimate at 80 m per minute.
func nearbyStations(candidates []NearbyCandidate, metrics []WalkingMetric) []*pb.NearStation {
	stations := make([]*pb.NearStation, 0, len(candidates))
	for i, item := range candidates {
		walk := int32(item.GeodesicMeters / 80)
		distance := int32(item.GeodesicMeters)
		routed := false
		if i < len(metrics) && metrics[i].DurationSeconds != nil {
			walk = int32(*metrics[i].DurationSeconds / 60)
			routed = true
			if metrics[i].DistanceMeters != nil {
				distance = int32(*metrics[i].DistanceMeters)
			}
		}
		stations = append(stations, &pb.NearStation{
			Type: int32(item.Mode), StationID: item.ID, StationName: item.Name,
			City: item.City, PositionLon: item.Point.Lon, PositionLat: item.Point.Lat,
			Walk: walk, Distance: distance, Routed: routed,
		})
	}
	return stations
}

func appendNearbyResult(response *pb.RespNear, mode NearbyMode, stations []*pb.NearStation) error {
	switch mode {
	case NearbyBus:
		for _, station := range stations {
			response.NearBusStations[station.StationID] = &pb.ArrayNear{NearStations: []*pb.NearStation{station}}
		}
	case _nearbyBike:
		response.NearBikeStations = stations
	case _nearbyMRT:
		response.NearMrtStations = stations
	case _nearbyTRA:
		response.NearTraStations = stations
	case _nearbyTHSR:
		response.NearThsrStations = stations
	default:
		return _oops.With("mode", mode).Errorf("unknown nearby mode")
	}
	return nil
}

func isContextError(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}
