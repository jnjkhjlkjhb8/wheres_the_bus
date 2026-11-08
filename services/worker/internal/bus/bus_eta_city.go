package bus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
	"go.uber.org/zap"
)

type busCityFeeds struct {
	eat                     []busmodel.RawEstimated
	posit                   []busmodel.RawPosition
	etaRaw, positionRaw     []byte
	etaFetch, positionFetch *shared.TDXFetch
	etaModified             bool
}

func (j busLiveJob) runCity(ctx context.Context, city string) (err error) {
	published := false
	defer j.refreshFailedCity(ctx, city, &err, &published)
	if _, skip := _busEtaSkip[city]; skip {
		return nil
	}
	zap.S().Infow("city start", "component", "bus_eta", "action", "Bus_eta", "city", city, "event", "city_start")
	prefix := busmodel.CityPrefix[city]
	if prefix == "" {
		zap.S().Warnw("skip empty", "component", "bus_eta", "action", "Bus_eta", "city", city, "event", "skip_empty", "reason", "no_prefix")
		return nil
	}
	return j.publishStaticCity(ctx, city, prefix, &published)
}

func (j busLiveJob) publishStaticCity(ctx context.Context, city, prefix string, published *bool) error {
	mp, err := j.cityStaticStops(ctx, city, prefix)
	if err != nil {
		return err
	}
	if len(mp) == 0 {
		return nil
	}
	return j.publishCity(ctx, city, mp, published)
}

// _busFailureRefreshWindow is how long after a city's last successful publish a
// failing tick may still re-arm the city's live keys. Past it the keys expire,
// so a city that keeps failing goes dark instead of serving stale arrivals.
const _busFailureRefreshWindow = 5 * time.Minute

func (j busLiveJob) refreshFailedCity(ctx context.Context, city string, err *error, published *bool) {
	if !j.failureRefreshAllowed(ctx, city, *err, *published) {
		return
	}
	if refreshErr := j.sink.RefreshTTL(ctx, busEtaTTLPatterns(city)); refreshErr != nil {
		*err = errors.Join(*err, refreshErr)
	}
}

func (j busLiveJob) failureRefreshAllowed(ctx context.Context, city string, err error, published bool) bool {
	return needsCityFailureRefresh(ctx, err, published) && j.publishedRecently(ctx, city)
}

func needsCityFailureRefresh(ctx context.Context, err error, published bool) bool {
	return err != nil && !published && ctx.Err() == nil
}

// publishedRecently treats an unreadable marker like a missing one: without
// proof of a recent publish, the stale keys are left to expire.
func (j busLiveJob) publishedRecently(ctx context.Context, city string) bool {
	_, err := j.sink.GetString(ctx, shared.BusCityPublishedKey(city))
	return err == nil
}

func (j busLiveJob) cityStaticStops(ctx context.Context, city, prefix string) ([]busmodel.StationMap, error) {
	generation := j.staticGeneration(ctx, city)
	mp, cached := predict.CachedStaticMapFrom(predict.StaticMapCache(), prefix, generation, j.now())
	if !cached {
		return j.loadStaticStops(ctx, city, prefix, generation)
	}
	return nonemptyStaticStops(city, mp), nil
}

func (j busLiveJob) staticGeneration(ctx context.Context, city string) string {
	generation, err := j.sink.GetString(ctx, shared.BusStaticGenerationKey(city))
	// During a Redis outage, the local static cache still expires by its bounded TTL.
	if err != nil {
		return ""
	}
	return generation
}

func (j busLiveJob) loadStaticStops(ctx context.Context, city, prefix, generation string) ([]busmodel.StationMap, error) {
	mp, err := j.store.staticStops(ctx, prefix)
	if err != nil {
		return nil, _oops.With("city", city).Wrapf(err, "load static stops")
	}
	mp = nonemptyStaticStops(city, mp)
	if len(mp) != 0 {
		predict.StoreStaticMapIn(predict.StaticMapCache(), prefix, mp, generation, j.now())
	}
	return mp, nil
}

func nonemptyStaticStops(city string, mp []busmodel.StationMap) []busmodel.StationMap {
	if len(mp) == 0 {
		zap.S().Warnw("skip empty", "component", "bus_eta", "action", "Bus_eta", "city", city, "event", "skip_empty", "reason", "no_stations")
		return nil
	}
	return mp
}

func (j busLiveJob) loadCityETA(ctx context.Context, city string, f *busCityFeeds) error {
	f.etaModified = true
	if source, ok := j.eta[city]; ok {
		return loadDirectCityETA(ctx, city, f, source)
	}
	return j.loadTDXCityETA(ctx, city, f)
}

func loadDirectCityETA(ctx context.Context, city string, f *busCityFeeds, source etaSource) error {
	var err error
	f.eat, err = source.estimates(ctx)
	if err != nil {
		return _oops.With("city", city).Wrapf(err, "fetch bus ETA")
	}
	f.etaRaw, err = json.Marshal(f.eat)
	return err
}

func busCityFeedURL(dataset, city string) string {
	if city == "InterCity" {
		return "/v2/Bus/" + dataset + "/InterCity"
	}
	return fmt.Sprintf("/v2/Bus/%s/City/%s", dataset, city)
}

func (j busLiveJob) loadTDXCityETA(ctx context.Context, city string, f *busCityFeeds) error {
	var err error
	f.etaFetch, err = j.fetch(ctx, busCityFeedURL("EstimatedTimeOfArrival", city), "bus_EstimatedTimeOfArrival"+city)
	if err != nil {
		return _oops.With("city", city).Wrapf(err, "fetch bus ETA")
	}
	f.etaModified = f.etaFetch.Modified
	if f.etaModified {
		return decodeCityETA(city, f)
	}
	return nil
}

func decodeCityETA(city string, f *busCityFeeds) error {
	var err error
	var decodeErr error
	f.eat, decodeErr = decodeBusEtaArray(f.etaFetch.Decoder)
	closeErr := f.etaFetch.Close()
	if decodeErr != nil {
		decodeErr = _oops.With("city", city).Wrapf(decodeErr, "decode bus ETA response")
	}
	if err := errors.Join(decodeErr, closeErr); err != nil {
		return err
	}
	f.etaRaw, err = json.Marshal(f.eat)
	return err
}

func (j busLiveJob) loadCityPositions(ctx context.Context, city string, f *busCityFeeds) error {
	var err error
	f.posit = make([]busmodel.RawPosition, 0)
	positionURL := busCityFeedURL("RealTimeByFrequency", city)
	f.positionFetch, err = j.fetch(ctx, positionURL, "bus_RealTimeByFrequency"+city)
	if err != nil {
		return _oops.With("city", city).Wrapf(err, "fetch bus positions")
	}
	if f.positionFetch.Modified {
		return decodeCityPositions(f)
	}
	return nil
}

// loadPositions never fails the city: without positions the ETA still
// publishes, only without vehicles on the map.
func (j busLiveJob) loadPositions(ctx context.Context, city string, f *busCityFeeds) {
	// Data.taipei cities take vehicles from their own feed (overlayVehicles) and
	// never spend TDX quota on positions.
	if _, ok := j.vehicles[city]; ok {
		return
	}
	if err := j.loadCityPositions(ctx, city, f); err != nil {
		dropCityPositions(city, f, err)
	}
}

// dropCityPositions also forgets the fetch, so a failed or half-decoded
// position feed is never acknowledged and the next tick fetches it again.
func dropCityPositions(city string, f *busCityFeeds, err error) {
	zap.S().Warnw("positions unavailable; publishing without positions",
		"component", "bus_eta",
		"action", "Bus_eta",
		"city", city,
		"event", "positions_dropped",
		"err", err,
	)
	f.posit = make([]busmodel.RawPosition, 0)
	f.positionRaw = nil
	f.positionFetch = nil
}

func decodeCityPositions(f *busCityFeeds) error {
	decodeErr := pipeline.DecodeLiveItems(f.positionFetch.Decoder, func(p busmodel.RawPosition) error {
		f.posit = append(f.posit, p)
		return nil
	})
	closeErr := f.positionFetch.Close()
	if err := errors.Join(decodeErr, closeErr); err != nil {
		return err
	}
	raw, err := json.Marshal(f.posit)
	f.positionRaw = raw
	return err
}

func (j busLiveJob) cacheCityFeeds(ctx context.Context, city string, f *busCityFeeds, pipe pipeline.LivePipe) error {
	j.cachePositionFeed(ctx, city, f, pipe)
	if err := cacheBusFeed(ctx, j.sink, pipe, shared.BusETARawKey(city), f.etaModified, f.etaRaw, &f.eat); err != nil {
		return j.failedFeedCache(ctx, f, pipe, err)
	}
	return nil
}

func (j busLiveJob) cachePositionFeed(ctx context.Context, city string, f *busCityFeeds, pipe pipeline.LivePipe) {
	if f.positionFetch == nil {
		return
	}
	if err := cacheBusFeed(ctx, j.sink, pipe, shared.BusPositionRawKey(city), f.positionFetch.Modified, f.positionRaw, &f.posit); err != nil {
		dropUncachedPositions(city, f, err)
	}
}

// dropUncachedPositions handles a 304 whose cached rows are gone: invalidating
// the marker makes the next tick fetch the full position feed again.
func dropUncachedPositions(city string, f *busCityFeeds, err error) {
	dropCityPositions(city, f, errors.Join(err, pipeline.InvalidateTDXFetch(f.positionFetch)))
}

func cacheBusFeed[T any](ctx context.Context, sink pipeline.LiveSink, pipe pipeline.LivePipe, key string, modified bool, raw []byte, rows *[]T) error {
	if modified {
		pipe.Set(key, raw, _busFeedCacheTTL)
		return nil
	}
	cached, err := readBusFeedCache[T](ctx, sink, key)
	*rows = cached
	if err != nil {
		return err
	}
	pipe.Expire(key, _busFeedCacheTTL)
	return nil
}

func (j busLiveJob) failedFeedCache(ctx context.Context, f *busCityFeeds, pipe pipeline.LivePipe, cacheErr error) error {
	execErr := pipe.Exec(ctx)
	var ackErr error
	if execErr == nil {
		ackErr = acknowledgeCityFeeds(f)
	}
	return errors.Join(cacheErr, execErr, ackErr, invalidateUnmodifiedCityFeeds(f))
}

func invalidateUnmodifiedCityFeeds(f *busCityFeeds) error {
	invalidateErr := invalidateETAFeed(f)
	if f.positionFetch != nil && !f.positionFetch.Modified {
		invalidateErr = errors.Join(invalidateErr, pipeline.InvalidateTDXFetch(f.positionFetch))
	}
	return invalidateErr
}

func invalidateETAFeed(f *busCityFeeds) error {
	if f.etaFetch != nil && !f.etaModified {
		return pipeline.InvalidateTDXFetch(f.etaFetch)
	}
	return nil
}

func acknowledgeCityFeeds(f *busCityFeeds) error {
	ackErr := acknowledgeETAFeed(f)
	if positionsModified(f) {
		ackErr = errors.Join(ackErr, pipeline.AcknowledgeTDXFetch(f.positionFetch))
	}
	return ackErr
}

func positionsModified(f *busCityFeeds) bool {
	return f.positionFetch != nil && f.positionFetch.Modified
}

func acknowledgeETAFeed(f *busCityFeeds) error {
	if f.etaModified && f.etaFetch != nil {
		return pipeline.AcknowledgeTDXFetch(f.etaFetch)
	}
	return nil
}

func (j busLiveJob) finishCity(ctx context.Context, city string, f *busCityFeeds, r *busCitySnapshot) error {
	if j.notifier != nil {
		if err := j.notifier.Arrivals(ctx, r.arrivalEvents); err != nil {
			return _oops.With("city", city).Wrapf(err, "dispatch bus arrival reminders")
		}
	}
	j.saveModifiedCityHistory(ctx, f, r)
	return nil
}

func (j busLiveJob) saveModifiedCityHistory(ctx context.Context, f *busCityFeeds, r *busCitySnapshot) {
	if f.etaModified || positionsModified(f) {
		j.store.saveHistory(ctx, r.historyRows)
		j.store.recordPredictions(ctx, r.predictionRows)
	}
}

func (j busLiveJob) publishCity(ctx context.Context, city string, mp []busmodel.StationMap, published *bool) error {
	f := &busCityFeeds{}
	if err := j.loadCityETA(ctx, city, f); err != nil {
		return err
	}
	j.loadPositions(ctx, city, f)
	return j.publishLoadedCity(ctx, city, mp, f, published)
}

func (j busLiveJob) publishLoadedCity(ctx context.Context, city string, mp []busmodel.StationMap, f *busCityFeeds, published *bool) error {
	pipe := j.sink.Pipe()
	if err := j.cacheCityFeeds(ctx, city, f, pipe); err != nil {
		return err
	}
	r := j.prepareCitySnapshot(ctx, city, mp, f)
	r.resolveStops(mp)
	if err := r.queueSnapshots(pipe); err != nil {
		return err
	}
	// Written in the snapshot's own pipeline, so the marker exists only once the
	// snapshot has actually published.
	pipe.Set(shared.BusCityPublishedKey(city), "1", _busFailureRefreshWindow)
	return j.commitPublishedCity(ctx, city, f, r, pipe, published)
}

func (j busLiveJob) commitPublishedCity(ctx context.Context, city string, f *busCityFeeds, r *busCitySnapshot, pipe pipeline.LivePipe, published *bool) error {
	if err := j.executeCitySnapshot(ctx, city, f, r, pipe); err != nil {
		return err
	}
	*published = true
	if err := acknowledgeCityFeeds(f); err != nil {
		return err
	}
	return j.finishCity(ctx, city, f, r)
}
