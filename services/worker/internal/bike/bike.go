package bike

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
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

// _bikeHistorySampleGate is the process-wide 5-minute-per-station gate shared
// across Eta rounds, so history sampling survives between 30s ticks.
var _bikeHistorySampleGate bikeHistorySampler

func Eta(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink, db *pgxpool.Pool) error {
	zap.S().Infow("start", "component", "bike_eta", "action", "bike_eta", "event", "start")
	now := time.Now()
	var (
		historyRows [][]any
		jobErr      error
	)
	for _, city := range busmodel.Cities {
		if _, skip := _bikeAvailabilitySkip[city]; skip {
			continue
		}
		if !pipeline.LiveDemandGate(ctx, sink, "bike", city) {
			ownedKey := shared.LiveOwnedKeysKey("bike", city)
			if err := sink.RefreshOwnedTTL(ctx, ownedKey, pipeline.BikeLiveTTL); err != nil {
				pipe := sink.Pipe()
				pipe.Expire(shared.LiveColdKey("bike", city), 0)
				if execErr := pipe.Exec(ctx); execErr != nil {
					err = errors.Join(err, _oops.Wrapf(execErr, "drop bike cadence claim"))
				}
				jobErr = errors.Join(jobErr,
					_oops.With("city", city).Wrapf(err, "refresh unwatched bike TTLs"))
			}
			continue
		}
		zap.S().Infow("city start",
			"component", "bike_eta",
			"action", "bike_eta",
			"city", city,
			"event", "city_start",
		)
		result, err := fetch(ctx, fmt.Sprintf("/v2/Bike/Availability/City/%s", city), "bike_availability"+city)
		if err != nil {
			jobErr = errors.Join(jobErr, _oops.With("city", city).Wrapf(err, "bike fetch"))
			continue
		}
		if !result.Modified {
			// A 304 is the expected answer most ticks: the cadence is well under
			// how often the operators republish. Logged at info because a warning
			// here is 840 lines an hour that never once means anything is wrong.
			zap.S().Warnw("skip",
				"component", "bike_eta",
				"action", "bike_eta",
				"city", city,
				"event", "skip",
				"reason", "not_modified",
			)
			continue
		}
		if err := pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error {
			pipe := sink.Pipe()
			ownedKeys := make([]string, 0)
			if err := pipeline.DecodeLiveItems(dec, func(temp bikeAvailability) error {
				availableRent := int(temp.AvailableRentBikesDetail.GeneralBikes) + int(temp.AvailableRentBikesDetail.ElectricBikes)
				raw := &models.BikeEta{
					StationUID:           temp.StationUID,
					ServiceStatus:        int32(temp.ServiceStatus),
					ServiceType:          int32(temp.ServiceType),
					AvailableReturnBikes: temp.AvailableReturnBikes,
					GeneralBikes:         temp.AvailableRentBikesDetail.GeneralBikes,
					ElectricBikes:        temp.AvailableRentBikesDetail.ElectricBikes,
				}
				pb, err := proto.Marshal(raw)
				if err != nil {
					return err
				}
				key := shared.BikeAvailabilityKey(temp.StationUID)
				pipe.Set(key, pb, pipeline.BikeLiveTTL)
				observedAtKey := shared.BikeAvailabilityObservedAtKey(temp.StationUID)
				pipe.Set(observedAtKey, now.Unix(), pipeline.BikeLiveTTL)
				ownedKeys = append(ownedKeys, key)
				// Sample into history at most once per 5 minutes per station.
				if db != nil && _bikeHistorySampleGate.shouldSample(temp.StationUID, now) {
					historyRows = append(historyRows, []any{
						temp.StationUID, availableRent, int(temp.AvailableReturnBikes), now,
					})
				}
				return nil
			}); err != nil {
				return err
			}
			pipe.ReplaceOwnedKeys(shared.LiveOwnedKeysKey("bike", city), ownedKeys, pipeline.OwnedKeysTTL)
			if err := pipe.Exec(ctx); err != nil {
				return _oops.With("city", city).Wrapf(err, "publish bike availability")
			}
			zap.S().Infow("complete", "component", "bike_eta", "action", "bike_eta", "city", city, "event", "complete")
			return nil
		}); err != nil {
			jobErr = errors.Join(jobErr, _oops.With("city", city).Wrapf(err, "bike process"))
		}
	}
	saveBikeAvailabilityHistory(ctx, history.Target(), historyRows)
	zap.S().Infow("complete", "component", "bike_eta", "action", "bike_eta", "event", "complete")
	return jobErr
}
