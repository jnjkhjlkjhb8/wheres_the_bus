package bike

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

// _bikeAvailabilitySkip lists the cities TDX serves no Bike/Availability feed
// for; Eta skips them rather than spending a request per tick on a 404.

// bikeStation is the subset of a TDX Bike/Station record used for the static
// station table (identity, name, coordinates, capacity).
type bikeStation struct {
	StationUID  string `json:"StationUID"`
	StationID   string `json:"StationID"`
	StationName struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"StationName"`
	StationPosition struct {
		PositionLon float64 `json:"PositionLon"`
		PositionLat float64 `json:"PositionLat"`
	} `json:"StationPosition"`
	StationAddress struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"StationAddress"`
	BikesCapacity int32 `json:"BikesCapacity"`
	ServiceType   uint8 `json:"ServiceType"`
}

// bikeAvailability is the subset of a TDX Bike/Availability record used for the
// realtime bike ETA cache (live rentable/returnable counts per station).

func LoadStations(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, city string) error {
	if strings.TrimSpace(city) == "" {
		return errors.New("bike stations: city is required")
	}
	stations, err := pipeline.DecodeLoadArray[bikeStation](dec, "bike stations "+city, func(_ int, station bikeStation) error {
		if strings.TrimSpace(station.StationUID) == "" {
			return errors.New("StationUID is required")
		}
		if strings.TrimSpace(station.StationID) == "" {
			return errors.New("StationID is required")
		}
		if !pipeline.ValidPosition(station.StationPosition.PositionLon, station.StationPosition.PositionLat) {
			return _oops.With("position_lon", station.StationPosition.PositionLon).With("position_lat", station.StationPosition.PositionLat).Errorf("position is invalid: lon= lat=")
		}
		// ServiceType is stored and served as an opaque smallint, never
		// switched on, so an operator TDX adds later must not reject the
		// city. A value this loader has not seen flows through unchanged.
		return nil
	})
	if err != nil {
		return err
	}
	row := [][]any{}
	seen := make(map[string][]any, len(stations))
	for _, temp := range stations {
		g := fmt.Sprintf("POINT(%.6f %.6f)", temp.StationPosition.PositionLon, temp.StationPosition.PositionLat)
		candidate := []any{
			temp.StationUID,
			temp.StationID,
			strings.TrimPrefix(temp.StationName.ZhTw, "YouBike2.0_"),
			temp.BikesCapacity,
			temp.ServiceType,
			city,
			g,
			temp.StationAddress.ZhTw,
		}
		if err := pipeline.AppendUniqueLoadRow(&row, seen, temp.StationUID, "StationUID", candidate); err != nil {
			return _oops.With("city", city).Wrapf(err, "bike stations")
		}
	}
	if len(row) == 0 {
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "bike",
		CreateSQL: `CREATE TEMP TABLE temp_bike (
                            uid text,
                            id text,
                            name text,
                            cap int,
                            type int,
							city text,
                            geom text,
                            addr text
					) ON COMMIT DROP`,
		TempTable: "temp_bike",
		CopyCols:  []string{"uid", "id", "name", "cap", "type", "city", "geom", "addr"},
		InsertSQL: `INSERT INTO bike_stations (
                           station_uid,
                           station_id,
                           name,
                           capacity,
                           service_type,
						   city,
                           geom,
                           address,
                           updated_at
					)
					SELECT uid, id, name, cap, type, city,st_geomfromtext(geom, 4326) AS temp, addr AS address,NOW() FROM temp_bike
					ON CONFLICT (station_uid) DO UPDATE SET station_id = EXCLUDED.station_id,name = EXCLUDED.name,capacity = EXCLUDED.capacity,service_type = EXCLUDED.service_type,city = excluded.city,geom = EXCLUDED.geom,address = EXCLUDED.address,updated_at = NOW();`,
	}, row)
}

// _bikeHistorySampleGate is the process-wide 5-minute-per-station gate shared
// across Eta rounds, so history sampling survives between 30s ticks.

// A 304 is the expected answer most ticks: the cadence is well under
// how often the operators republish. Logged at info because a warning
// here is 840 lines an hour that never once means anything is wrong.

// Sample into history at most once per 5 minutes per station.
