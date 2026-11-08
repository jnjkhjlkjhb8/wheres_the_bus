package bus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"runtime/debug"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

// etaKey identifies one TDX ETA entry by its canonical subroute, derived
// direction, and stop. TDX emits one entry per (stop x subroute x direction),
// so keying on all three keeps multi-route stops from overwriting each other.
type etaKey struct {
	subRouteUID string
	direction   uint8
	stopUID     string
}

func busPositionIdentity(subRouteUID string, direction uint8) string {
	return fmt.Sprintf("%s\x00%d", subRouteUID, direction)
}

// _busPlatePassedStop is the value TDX sends in an N1 PlateNumb to say the
// vehicle has already passed that stop. It names no vehicle, so it must not
// reach the wire, an arrival push, or a history row's vehicle identity.
const _busPlatePassedStop = "-1"

func normalizeArrivalPlate(plate string) string {
	normalized := strings.ToUpper(strings.TrimSpace(plate))
	if normalized == _busPlatePassedStop {
		return ""
	}
	return normalized
}

const _busPositionMaxAge = 10 * time.Minute

// positionFresh reports whether a vehicle's GPS reading is recent enough to
// publish. An unparseable GPSTime (gpsTimeUnix 0) is kept: it carries no age to
// judge, and the app already renders it as 無定位.
func positionFresh(gpsTimeUnix int64, now time.Time) bool {
	if gpsTimeUnix == 0 {
		return true
	}
	return now.Sub(time.Unix(gpsTimeUnix, 0)) <= _busPositionMaxAge
}

func buildDirectionAwareBusPositionMap(city string, positions []busmodel.RawPosition, now time.Time) map[string][]*models.BusPosition {
	byIdentity := make(map[string][]*models.BusPosition)
	for _, position := range positions {
		gpsTimeUnix := parseGPSTimeUnix(position.GPSTime)
		if !positionFresh(gpsTimeUnix, now) {
			continue
		}
		uid, direction := shared.CanonicalSubroute(city, position.SubRouteUID, position.Direction)
		key := busPositionIdentity(uid, direction)
		byIdentity[key] = append(byIdentity[key], &models.BusPosition{
			PlateNumb:   position.PlateNumb,
			PositionLon: position.BusPosition.PositionLon,
			PositionLat: position.BusPosition.PositionLat,
			Speed:       int32(position.Speed),
			// Rounded, not truncated: the wire field is whole degrees, and a
			// fractional bearing is a real reading rather than a value with a
			// meaningful floor — 359.6° is north, not 359°.
			Azimuth:     int32(math.Round(position.Azimuth)),
			DutyStatus:  int32(position.DutyStatus),
			BusStatus:   int32(position.BusStatus),
			GpsTimeUnix: gpsTimeUnix,
			// Unset for every feed but Data.taipei's, which is what the wire enum's
			// zero value means (models/bus.proto).
			CrowdLevel: position.CrowdLevel,
		})
	}
	return byIdentity
}

// ArrivalNotifier receives each tick's arrival events: riderevent.Publisher in
// production, which hands them to rider for reminder dispatch.
type ArrivalNotifier interface {
	Arrivals(context.Context, []riderevent.ArrivalEvent) error
}

type busArrivalBatch struct {
	mu     sync.Mutex
	target ArrivalNotifier
	events []riderevent.ArrivalEvent
}

func (b *busArrivalBatch) Arrivals(_ context.Context, events []riderevent.ArrivalEvent) error {
	b.mu.Lock()
	b.events = append(b.events, events...)
	b.mu.Unlock()
	return nil
}

func (b *busArrivalBatch) flush(ctx context.Context) error {
	if b.target == nil {
		return nil
	}
	b.mu.Lock()
	events := append([]riderevent.ArrivalEvent(nil), b.events...)
	b.events = nil
	b.mu.Unlock()
	return b.target.Arrivals(ctx, events)
}

var _busEtaSkip = map[string]struct{}{
	"LienchiangCounty": {},
}

type vehicleSource interface {
	positions(context.Context) ([]busmodel.RawPosition, error)
}

type busLiveJob struct {
	fetch    pipeline.BoundFetch
	sink     pipeline.LiveSink
	store    busEtaStore
	notifier ArrivalNotifier
	vehicles map[string]vehicleSource
	eta      map[string]etaSource
	now      func() time.Time
	// snapshot is fixed for the whole run so every city lands on the same side
	// of the history sampling clock (see snapshotTick).
	snapshot bool
	demand   busDemand
}

// busDemand gates a job's cities on live demand. An empty dataset leaves the
// job ungated, as Data.taipei costs no TDX quota.
type busDemand struct {
	dataset string
	guard   *pipeline.LiveFetchGuard
}

const _busFeedCacheTTL = 10 * time.Minute

var errBusFeedCacheMiss = errors.New("bus raw feed cache missing")

func readBusFeedCache[T any](ctx context.Context, sink pipeline.LiveSink, key string) ([]T, error) {
	raw, err := sink.GetString(ctx, key)
	if busFeedCacheMissing(raw, err) {
		return nil, _oops.With("key", key).Wrapf(errBusFeedCacheMiss, "bus feed cache lookup")
	}
	if err != nil {
		return nil, _oops.With("key", key).Wrapf(err, "read")
	}
	return decodeBusFeedCache[T](raw, key)
}

func busFeedCacheMissing(raw string, err error) bool {
	return errors.Is(err, redis.Nil) || err == nil && raw == ""
}

func decodeBusFeedCache[T any](raw, key string) ([]T, error) {
	var values []T
	if err := json.Unmarshal([]byte(raw), &values); err != nil {
		return nil, _oops.With("key", key).Wrapf(err, "decode")
	}
	if values == nil {
		return nil, _oops.With("key", key).Wrapf(errBusFeedCacheMiss, "contains JSON null")
	}
	return values, nil
}

func pickBusEstimate(prev, next busmodel.RawEstimated) busmodel.RawEstimated {
	if next.StopStatus != 0 {
		return prev
	}
	if prev.StopStatus != 0 {
		return next
	}
	if next.EstimatedTime < prev.EstimatedTime {
		return next
	}
	return prev
}

func decodeBusEtaArray(dec *json.Decoder) (eat []busmodel.RawEstimated, err error) {
	eat = make([]busmodel.RawEstimated, 0)
	if err := readBusEtaOpening(dec); err != nil {
		return nil, err
	}
	for dec.More() {
		var e busmodel.RawEstimated
		if err := dec.Decode(&e); err != nil {
			return eat, fmt.Errorf("decode element %d: %w", len(eat), err)
		}
		eat = append(eat, e)
	}
	return eat, readBusEtaEnding(dec, len(eat))
}

func readBusEtaOpening(dec *json.Decoder) error {
	opening, err := dec.Token()
	if err != nil {
		return fmt.Errorf("read opening array token: %w", err)
	}
	if opening != json.Delim('[') {
		return fmt.Errorf("body is not a JSON array: opens with %v", opening)
	}
	return nil
}

func readBusEtaEnding(dec *json.Decoder, count int) error {
	closing, err := dec.Token()
	if err != nil {
		return fmt.Errorf("read closing array token after %d elements: %w", count, err)
	}
	if closing != json.Delim(']') {
		return fmt.Errorf("array does not close after %d elements: got %v", count, closing)
	}
	return rejectBusEtaTrailingData(dec, count)
}

func rejectBusEtaTrailingData(dec *json.Decoder, count int) error {
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return fmt.Errorf("trailing data after array of %d elements: %v (err %w)", count, trailing, err)
	}
	return nil
}

var _busEtaFastCities = func() []string {
	fast := make([]string, 0, len(_dataTaipeiDynamicCities))
	for city := range _dataTaipeiDynamicCities {
		fast = append(fast, city)
	}
	sort.Strings(fast)
	return fast
}()

// _busEtaSlowCities is cities minus busEtaFastCities: every city still polled
// for ETA on the shared "@every 30s" TDX cadence.
var _busEtaSlowCities = func() []string {
	fast := make(map[string]struct{}, len(_dataTaipeiDynamicCities))
	for _, city := range _busEtaFastCities {
		fast[city] = struct{}{}
	}
	slow := make([]string, 0, len(busmodel.Cities))
	for _, city := range busmodel.Cities {
		if _, isFast := fast[city]; !isFast {
			slow = append(slow, city)
		}
	}
	return slow
}()

// Eta refreshes live bus arrivals for busEtaSlowCities on the 30s cron.
// Cities are processed concurrently, capped at 4 in flight (sem). It blocks
// until every city finishes.
func Eta(
	ctx context.Context,
	fetch pipeline.BoundFetch,
	sink pipeline.LiveSink,
	db *pgxpool.Pool,
	notifier ArrivalNotifier,
	guard *pipeline.LiveFetchGuard,
) error {
	return runBusEtaTick(ctx, "bus_eta", _busEtaSlowCities, history.SnapshotTick(time.Now(), history.BusEtaTickInterval),
		nil, nil, fetch, sink, db, notifier, busDemand{dataset: "bus_eta", guard: guard})
}

// EtaCity runs Eta for one city at once, for a demand wake. A city outside
// busEtaSlowCities runs nothing: Taipei and New Taipei have demand keys too,
// but their data comes from Data.taipei and must never cost a TDX fetch. A
// wake run never samples history snapshots, because the tick that follows in
// the same window would sample the city again.
func EtaCity(
	ctx context.Context,
	city string,
	fetch pipeline.BoundFetch,
	sink pipeline.LiveSink,
	db *pgxpool.Pool,
	notifier ArrivalNotifier,
	guard *pipeline.LiveFetchGuard,
) error {
	if !slices.Contains(_busEtaSlowCities, city) {
		zap.S().Infow("skip", "component", "bus_eta", "action", "wake", "event", "skip", "city", city, "reason", "not_tdx_city")
		return nil
	}
	return runBusEtaTick(ctx, "bus_eta", []string{city}, false,
		nil, nil, fetch, sink, db, notifier, busDemand{dataset: "bus_eta", guard: guard})
}

func EtaFast(
	ctx context.Context,
	fetch pipeline.BoundFetch,
	sink pipeline.LiveSink,
	db *pgxpool.Pool,
	notifier ArrivalNotifier,
) error {
	// One feed per Data.taipei city, shared between the vehicle overlay and the
	// ETA override: both read the same blob container.
	vehicles := make(map[string]vehicleSource, len(_busEtaFastCities))
	etaFeeds := make(map[string]etaSource, len(_busEtaFastCities))
	for _, city := range _busEtaFastCities {
		feed := NewDataTaipeiFeed(city)
		vehicles[city] = feed
		etaFeeds[city] = feed
	}
	return runBusEtaTick(ctx, "bus_eta_fast", _busEtaFastCities, history.SnapshotTick(time.Now(), history.BusEtaFastTickInterval),
		vehicles, etaFeeds, fetch, sink, db, notifier, busDemand{})
}

// runBusEtaTick is the shared body of Eta, EtaCity and EtaFast: build the job,
// run cityList, log start/complete under component so the two crons are
// distinguishable in the logs.
func runBusEtaTick(
	ctx context.Context,
	component string,
	cityList []string,
	snapshot bool,
	vehicles map[string]vehicleSource,
	eta map[string]etaSource,
	fetch pipeline.BoundFetch,
	sink pipeline.LiveSink,
	db *pgxpool.Pool,
	notifier ArrivalNotifier,
	demand busDemand,
) error {
	zap.S().Infow("start", "component", component, "action", "Bus_eta", "event", "start", "snapshot", snapshot)
	job := busLiveJob{
		fetch:    fetch,
		sink:     sink,
		store:    pgBusEtaStore{db: db},
		vehicles: vehicles,
		eta:      eta,
		now:      time.Now,
		snapshot: snapshot,
		demand:   demand,
	}
	jobErr := runBusEtaCities(ctx, cityList, &job, notifier)
	zap.S().Infow("complete", "component", component, "action", "Bus_eta", "event", "complete")
	return jobErr
}

func (j busLiveJob) runCityGuarded(ctx context.Context, city string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = _oops.With("rows", r).Errorf("panic")
			zap.S().Errorw("panic",
				"component", "bus_eta",
				"action", "Bus_eta",
				"city", city,
				"event", "panic",
				"value", r,
				"stack", debug.Stack(),
			)
		}
	}()
	return j.runCity(ctx, city)
}

func (j busLiveJob) claimCity(ctx context.Context, city string) (release func(), ok bool) {
	if j.demand.dataset == "" {
		return func() {}, true
	}
	return pipeline.ClaimLiveDemand(ctx, j.sink, j.demand.guard, j.demand.dataset, city)
}

func runBusEtaCities(ctx context.Context, cityNames []string, job *busLiveJob, target ArrivalNotifier) error {
	arrivalBatch := &busArrivalBatch{target: target}
	job.notifier = arrivalBatch
	sem := make(chan struct{}, 4)
	errCh := make(chan error, len(cityNames))
	var wg sync.WaitGroup
	launchBusCities(ctx, cityNames, job, sem, errCh, &wg)
	wg.Wait()
	close(errCh)
	var jobErr error
	for err := range errCh {
		jobErr = errors.Join(jobErr, err)
	}
	if err := arrivalBatch.flush(ctx); err != nil {
		jobErr = errors.Join(jobErr, _oops.Wrapf(err, "dispatch bus arrival reminders"))
	}
	return jobErr
}

func skippedBusCity(city string) bool { return city == "ChanghuaCounty" || city == "NantouCounty" }

func launchBusCities(ctx context.Context, cityNames []string, job *busLiveJob, sem chan struct{}, errCh chan error, wg *sync.WaitGroup) {
	for _, city := range cityNames {
		if skippedBusCity(city) {
			continue
		}
		wg.Add(1)
		go func(city string) {
			defer wg.Done()
			runLimitedBusCity(ctx, city, job, sem, errCh)
		}(city)
	}

}

func runLimitedBusCity(ctx context.Context, city string, job *busLiveJob, sem chan struct{}, errCh chan error) {
	sem <- struct{}{}
	defer func() { <-sem }()
	if err := job.runDemandCity(ctx, city); err != nil {
		errCh <- err
	}
}

// runDemandCity fetches a city only while someone needs it. A city without
// demand is left alone, so its live keys expire.
func (j busLiveJob) runDemandCity(ctx context.Context, city string) error {
	release, ok := j.claimCity(ctx, city)
	if !ok {
		return nil
	}
	defer release()
	if err := j.runCityGuarded(ctx, city); err != nil {
		return _oops.With("city", city).Wrapf(err, "bus ETA city run")
	}
	return nil
}

func busEtaTTLPatterns(city string) []pipeline.TTLPattern {
	return []pipeline.TTLPattern{
		{Pattern: shared.BusStationEtaPattern(city), TTL: pipeline.BusLiveTTL},
		{Pattern: shared.BusRouteEtaPattern(busmodel.CityPrefix[city]), TTL: pipeline.BusLiveTTL},
	}
}

func shouldDispatchBusArrival(found bool, status uint8, etaSeconds int32) bool {
	return found && status == 0 && etaSeconds > 0
}
