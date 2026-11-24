package bike

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// _bikeAvailabilitySkip lists the cities TDX serves no Bike/Availability feed
// for; Eta skips them rather than spending a request per tick on a 404.
var _bikeAvailabilitySkip = map[string]struct{}{
	"Keelung":          {},
	"HsinchuCounty":    {},
	"NantouCounty":     {},
	"YilanCounty":      {},
	"PenghuCounty":     {},
	"KinmenCounty":     {},
	"LienchiangCounty": {},
	"InterCity":        {},
	"HualienCounty":    {},
}

// bikeStation is the subset of a TDX Bike/Station record used for the static
// station table (identity, name, coordinates, capacity).

// bikeAvailability is the subset of a TDX Bike/Availability record used for the
// realtime bike ETA cache (live rentable/returnable counts per station).
type bikeAvailability struct {
	StationUID               string `json:"StationUID"`
	StationID                string `json:"StationID"`
	ServiceStatus            uint8  `json:"ServiceStatus"`
	ServiceType              uint8  `json:"ServiceType"`
	AvailableReturnBikes     int32  `json:"AvailableReturnBikes"`
	AvailableRentBikesDetail struct {
		GeneralBikes  int32 `json:"GeneralBikes"`
		ElectricBikes int32 `json:"ElectricBikes"`
	} `json:"AvailableRentBikesDetail"`
}

// ServiceType is stored and served as an opaque smallint, never
// switched on, so an operator TDX adds later must not reject the
// city. A value this loader has not seen flows through unchanged.

// Eta refreshes bike availability for every city with live demand. The pool is
// unused; the parameter keeps the live-job signature uniform.
func Eta(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink, _ *pgxpool.Pool, guard *pipeline.LiveFetchGuard) error {
	return runBikeCities(ctx, busmodel.Cities, fetch, sink, guard)
}

// EtaCity runs Eta for one city at once, for a demand wake. A city TDX serves
// no availability for runs nothing.
func EtaCity(ctx context.Context, city string, fetch pipeline.BoundFetch, sink pipeline.LiveSink, _ *pgxpool.Pool, guard *pipeline.LiveFetchGuard) error {
	return runBikeCities(ctx, []string{city}, fetch, sink, guard)
}

func runBikeCities(ctx context.Context, cities []string, fetch pipeline.BoundFetch, sink pipeline.LiveSink, guard *pipeline.LiveFetchGuard) error {
	zap.S().Infow("start", "component", "bike_eta", "action", "bike_eta", "event", "start")
	now := time.Now()
	var jobErr error
	for _, city := range cities {
		if !bikeAvailabilityCity(city) {
			continue
		}
		jobErr = errors.Join(jobErr, runBikeCity(ctx, fetch, sink, guard, city, now))
	}
	zap.S().Infow("complete", "component", "bike_eta", "action", "bike_eta", "event", "complete")
	return jobErr
}

func bikeAvailabilityCity(city string) bool {
	_, skip := _bikeAvailabilitySkip[city]
	return !skip && slices.Contains(busmodel.Cities, city)
}

// runBikeCity fetches a city only while someone needs it. A city without
// demand is left alone, so its live keys expire.
func runBikeCity(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink, guard *pipeline.LiveFetchGuard, city string, now time.Time) error {
	release, ok := pipeline.ClaimLiveDemand(ctx, sink, guard, "bike", city)
	if !ok {
		return nil
	}
	defer release()
	zap.S().Infow("city start", "component", "bike_eta", "action", "bike_eta", "city", city, "event", "city_start")
	result, err := fetch(ctx, fmt.Sprintf("/v2/Bike/Availability/City/%s", city), "bike_availability"+city)
	if err != nil {
		return _oops.With("city", city).Wrapf(err, "bike fetch")
	}
	return commitBikeFetch(ctx, sink, result, city, now)
}

func commitBikeFetch(ctx context.Context, sink pipeline.LiveSink, result *shared.TDXFetch, city string, now time.Time) error {
	if !result.Modified {
		zap.S().Warnw("skip", "component", "bike_eta", "action", "bike_eta", "city", city, "event", "skip", "reason", "not_modified")
		return nil
	}
	err := pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error { return publishBikeCity(ctx, sink, dec, city, now) })
	if err != nil {
		return _oops.With("city", city).Wrapf(err, "bike process")
	}
	return nil
}

func publishBikeCity(ctx context.Context, sink pipeline.LiveSink, dec *json.Decoder, city string, now time.Time) error {
	pipe := sink.Pipe()
	ownedKeys := make([]string, 0)
	err := pipeline.DecodeLiveItems(dec, func(temp bikeAvailability) error {
		return queueBikeStation(pipe, temp, now, &ownedKeys)
	})
	if err != nil {
		return err
	}
	pipe.ReplaceOwnedKeys(shared.LiveOwnedKeysKey("bike", city), ownedKeys, pipeline.OwnedKeysTTL)
	if err := pipe.Exec(ctx); err != nil {
		return _oops.With("city", city).Wrapf(err, "publish bike availability")
	}
	zap.S().Infow("complete", "component", "bike_eta", "action", "bike_eta", "city", city, "event", "complete")
	return nil
}

func queueBikeAvailability(pipe pipeline.LivePipe, temp bikeAvailability, now time.Time) (string, error) {
	raw := &models.BikeEta{StationUID: temp.StationUID, ServiceStatus: int32(temp.ServiceStatus), ServiceType: int32(temp.ServiceType), AvailableReturnBikes: temp.AvailableReturnBikes, GeneralBikes: temp.AvailableRentBikesDetail.GeneralBikes, ElectricBikes: temp.AvailableRentBikesDetail.ElectricBikes}
	pb, err := proto.Marshal(raw)
	if err != nil {
		return "", err
	}
	key := shared.BikeAvailabilityKey(temp.StationUID)
	pipe.Set(key, pb, pipeline.BikeLiveTTL)
	pipe.Set(shared.BikeAvailabilityObservedAtKey(temp.StationUID), now.Unix(), pipeline.BikeLiveTTL)
	return key, nil
}

func queueBikeStation(pipe pipeline.LivePipe, temp bikeAvailability, now time.Time, ownedKeys *[]string) error {
	key, err := queueBikeAvailability(pipe, temp, now)
	if err != nil {
		return err
	}
	*ownedKeys = append(*ownedKeys, key)
	return nil
}
