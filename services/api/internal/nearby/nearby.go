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
		return nearbyModeResultWithContext(ctx, result)
	case <-ctx.Done():
		return nearbyModeResult{}, ctx.Err()
	}
}

func nearbyModeResultWithContext(ctx context.Context, result nearbyModeResult) (nearbyModeResult, error) {
	if err := ctx.Err(); err != nil {
		return nearbyModeResult{}, err
	}
	return result, nil
}

func validateNearbyQuery(query NearbyQuery) (NearbyQuery, error) {
	if err := validateNearbyOrigin(query.Origin); err != nil {
		return NearbyQuery{}, err
	}
	radius, err := nearbyRadius(query.RadiusMeters)
	if err != nil {
		return NearbyQuery{}, err
	}
	query.RadiusMeters = radius
	if query.Limit <= 0 {
		query.Limit = _defaultNearbyLimit
	}
	return query, nil
}

func validateNearbyOrigin(origin GeoPoint) error {
	if !validNearbyCoordinate(origin.Lon, 180) {
		return _oops.Wrapf(ErrInvalidNearbyQuery, "longitude must be finite and between -180 and 180")
	}
	if !validNearbyCoordinate(origin.Lat, 90) {
		return _oops.Wrapf(ErrInvalidNearbyQuery, "latitude must be finite and between -90 and 90")
	}
	return nil
}

func nearbyRadius(radius int) (int, error) {
	if radius == 0 {
		radius = _defaultNearbyRadius
	}
	if radius < 0 || radius > _maxNearbyRadius {
		return 0, _oops.With("_max_nearby_radius", _maxNearbyRadius).Wrapf(ErrInvalidNearbyQuery, "radius must be zero or between 1 and metres")
	}
	return (radius + _nearbyRadiusBucket - 1) / _nearbyRadiusBucket * _nearbyRadiusBucket, nil
}

func validNearbyCoordinate(value, limit float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && value >= -limit && value <= limit
}

func validateNearbyRequest(ctx context.Context, query NearbyQuery) (NearbyQuery, error) {
	if err := ctx.Err(); err != nil {
		return NearbyQuery{}, err
	}
	query, err := validateNearbyQuery(query)
	if err != nil {
		return NearbyQuery{}, err
	}
	return nearbyQueryWithContext(ctx, query)
}

func nearbyQueryWithContext(ctx context.Context, query NearbyQuery) (NearbyQuery, error) {
	if err := ctx.Err(); err != nil {
		return NearbyQuery{}, err
	}
	return query, nil
}

func (d *NearbyDiscovery) Discover(ctx context.Context, query NearbyQuery) (*pb.RespNear, error) {
	query, err := validateNearbyRequest(ctx, query)
	if err != nil {
		return nil, err
	}
	cacheKey := nearbyCacheKey(query)
	if cached, ok := d.cachedResponse(cacheKey); ok {
		return cached, nil
	}
	return d.discoverFresh(ctx, query, cacheKey)
}

func (d *NearbyDiscovery) discoverFresh(ctx context.Context, query NearbyQuery, cacheKey string) (*pb.RespNear, error) {
	workCtx, cancel := context.WithTimeout(ctx, _nearbyRequestTimeout)
	defer cancel()
	select {
	case nearbyBudget <- struct{}{}:
		defer func() { <-nearbyBudget }()
	case <-workCtx.Done():
		return nil, workCtx.Err()
	}
	response, err := d.discoverUncached(ctx, workCtx, query)
	if err != nil {
		return nil, err
	}
	d.cacheResponse(cacheKey, response)
	return response, nil
}

func (d *NearbyDiscovery) discoverUncached(ctx, workCtx context.Context, query NearbyQuery) (*pb.RespNear, error) {
	candidates, err := d.findAll(workCtx, query)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return d.enrich(workCtx, query.Origin, candidates)
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
			d.findMode(workerCtx, mode, query, results)
		}()
	}

	return collectNearbyModes(ctx, results)
}

func collectNearbyModes(ctx context.Context, results <-chan nearbyModeResult) (map[NearbyMode][]NearbyCandidate, error) {
	byMode := make(map[NearbyMode][]NearbyCandidate, len(AllNearbyModes))
	for range AllNearbyModes {
		result, err := receiveNearbyModeResult(ctx, results)
		if err != nil {
			return nil, err
		}
		if err := nearbyModeError(result); err != nil {
			return nil, err
		}
		byMode[result.mode] = result.candidates
	}
	return byMode, nil
}

func nearbyModeError(result nearbyModeResult) error {
	if result.queryError == nil {
		return nil
	}
	if isContextError(result.queryError) {
		return result.queryError
	}
	zap.S().Errorw("failed", "component", "near", "action", "query", "mode", result.mode,
		"event", "failed", "err", result.queryError)
	return ErrNearbyUnavailable
}

func (d *NearbyDiscovery) findMode(ctx context.Context, mode NearbyMode, query NearbyQuery, results chan<- nearbyModeResult) {
	candidates, err := d.store.Find(ctx, mode, query)
	select {
	case results <- nearbyModeResult{mode: mode, candidates: candidates, queryError: err}:
	case <-ctx.Done():
	}
}

func (d *NearbyDiscovery) enrich(ctx context.Context, origin GeoPoint, byMode map[NearbyMode][]NearbyCandidate) (*pb.RespNear, error) {
	points := nearbyPoints(byMode)
	metrics, err := d.walkingMetrics(ctx, origin, points)
	if err != nil {
		return nil, err
	}
	return nearbyResponse(byMode, metrics)
}

func nearbyPoints(byMode map[NearbyMode][]NearbyCandidate) []GeoPoint {
	points := make([]GeoPoint, 0, len(byMode)*_defaultNearbyLimit)
	for _, mode := range AllNearbyModes {
		for _, item := range byMode[mode] {
			points = append(points, item.Point)
		}
	}

	return points
}

func (d *NearbyDiscovery) walkingMetrics(ctx context.Context, origin GeoPoint, points []GeoPoint) ([]WalkingMetric, error) {
	metrics, routeErr := d.routeNearbyPoints(ctx, origin, points)
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

	return metrics, nil
}

func (d *NearbyDiscovery) routeNearbyPoints(ctx context.Context, origin GeoPoint, points []GeoPoint) ([]WalkingMetric, error) {
	if d.router == nil || len(points) == 0 {
		return nil, nil
	}
	return d.router.RouteMany(ctx, origin, points)
}

func nearbyResponse(byMode map[NearbyMode][]NearbyCandidate, metrics []WalkingMetric) (*pb.RespNear, error) {
	response := &pb.RespNear{NearBusStations: make(map[string]*pb.ArrayNear)}
	offset := 0
	for _, mode := range AllNearbyModes {
		candidates := byMode[mode]
		if err := appendNearbyMode(response, mode, candidates, metrics[min(offset, len(metrics)):]); err != nil {
			return nil, err
		}
		offset += len(candidates)
	}
	return response, nil
}

func appendNearbyMode(response *pb.RespNear, mode NearbyMode, candidates []NearbyCandidate, metrics []WalkingMetric) error {
	if len(candidates) == 0 {
		return nil
	}
	return appendNearbyResult(response, mode, nearbyStations(candidates, metrics))
}

// nearbyStations pairs candidates with the leading window of metrics; a short
// or absent window falls back to the geodesic estimate at 80 m per minute.
func nearbyStations(candidates []NearbyCandidate, metrics []WalkingMetric) []*pb.NearStation {
	stations := make([]*pb.NearStation, 0, len(candidates))
	for i, item := range candidates {
		walk, distance, routed := nearbyStationTravel(item, i, metrics)
		stations = append(stations, &pb.NearStation{
			Type: int32(item.Mode), StationID: item.ID, StationName: item.Name,
			City: item.City, PositionLon: item.Point.Lon, PositionLat: item.Point.Lat,
			Walk: walk, Distance: distance, Routed: routed,
		})
	}
	return stations
}

func nearbyStationTravel(item NearbyCandidate, index int, metrics []WalkingMetric) (int32, int32, bool) {
	walk, distance := int32(item.GeodesicMeters/80), int32(item.GeodesicMeters)
	if index >= len(metrics) || metrics[index].DurationSeconds == nil {
		return walk, distance, false
	}
	walk = int32(*metrics[index].DurationSeconds / 60)
	if metrics[index].DistanceMeters != nil {
		distance = int32(*metrics[index].DistanceMeters)
	}
	return walk, distance, true
}

func appendNearbyResult(response *pb.RespNear, mode NearbyMode, stations []*pb.NearStation) error {
	if mode == NearbyBus {
		for _, station := range stations {
			response.NearBusStations[station.StationID] = &pb.ArrayNear{NearStations: []*pb.NearStation{station}}
		}
		return nil
	}
	destination, ok := map[NearbyMode]*[]*pb.NearStation{
		_nearbyBike: &response.NearBikeStations,
		_nearbyMRT:  &response.NearMrtStations,
		_nearbyTRA:  &response.NearTraStations,
		_nearbyTHSR: &response.NearThsrStations,
	}[mode]
	if !ok {
		return _oops.With("mode", mode).Errorf("unknown nearby mode")
	}
	*destination = stations
	return nil
}

func isContextError(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}
