package bus

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

// rawBusDisplayStopOfRoute decodes one element: a route direction and its
// linearised stop list.
type rawBusDisplayStopOfRoute struct {
	RouteUID  string `json:"RouteUID"`
	Direction uint8  `json:"Direction"`
	Stops     []struct {
		StopUID  string `json:"StopUID"`
		StopName struct {
			Zhtw string `json:"Zh_tw"`
		} `json:"StopName"`
		StopSequence uint8  `json:"StopSequence"`
		StationID    string `json:"StationID"`
	} `json:"Stops"`
}

func LoadDisplayStops(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, city string) error {
	prefix, err := busDisplayCityPrefix(city)
	if err != nil {
		return err
	}
	routes, err := pipeline.DecodeLoadArray[rawBusDisplayStopOfRoute](dec, "bus display stops "+city, busDisplayRouteValidator(city, prefix))
	if err != nil {
		return err
	}
	return writeBusDisplayStops(ctx, sink, city, prefix, routes)
}

func busDisplayCityPrefix(city string) (string, error) {
	if strings.TrimSpace(city) == "" {
		return "", errors.New("bus display stops: city is required")
	}
	prefix := busmodel.CityPrefix[city]
	if prefix == "" {
		return "", _oops.With("city", city).Errorf("bus display stops: city has no UID prefix")
	}
	return prefix, nil
}

func busDisplayRouteValidator(city, prefix string) func(int, rawBusDisplayStopOfRoute) error {
	return func(_ int, route rawBusDisplayStopOfRoute) error {
		return validateBusDisplayRouteUID(city, prefix, route.RouteUID)
	}
}

func validateBusDisplayRouteUID(city, prefix, uid string) error {
	if !uidBelongsToPrefix(uid, prefix) {
		return _oops.With("route_uid", uid).With("city", city).Errorf("RouteUID does not belong")
	}
	return nil
}

func writeBusDisplayStops(ctx context.Context, sink pipeline.CopyUpsertSink, city, prefix string, routes []rawBusDisplayStopOfRoute) error {
	rows := busDisplayStopRows(routes)
	if len(rows) == 0 {
		zap.S().Infow("no display stops",
			"component", "bus_displaystops",
			"action", "bus_displaystop",
			"city", city,
			"event", "no_display_stops",
		)
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "bus_displaystop",
		// Partition-replace, so a stop dropped from a route leaves with it. The
		// upsert alone would keep it forever, and a stale stop in a route's own
		// stop list is exactly the defect this list exists to avoid.
		PreExec: []pipeline.CopyUpsertStmt{{
			SQL:  `DELETE FROM bus_display_stop_map WHERE route_uid LIKE $1`,
			Args: []any{prefix + "%"},
		}},
		CreateSQL: `CREATE TEMP TABLE temp_bus_display_stop (
			route_uid text, direction smallint, stop_uid text,
			stop_sequence smallint, station_id text, stop_name text
		) ON COMMIT DROP`,
		TempTable: "temp_bus_display_stop",
		CopyCols:  []string{"route_uid", "direction", "stop_uid", "stop_sequence", "station_id", "stop_name"},
		InsertSQL: `INSERT INTO bus_display_stop_map (
			route_uid, direction, stop_uid, stop_sequence, station_id, stop_name, updated_at)
		SELECT DISTINCT ON (route_uid, direction, stop_uid)
			route_uid, direction, stop_uid, stop_sequence, station_id, stop_name, NOW()
		FROM temp_bus_display_stop
		ORDER BY route_uid, direction, stop_uid, stop_sequence
		ON CONFLICT (route_uid, direction, stop_uid) DO UPDATE SET
			stop_sequence = EXCLUDED.stop_sequence,
			station_id = EXCLUDED.station_id,
			stop_name = EXCLUDED.stop_name,
			updated_at = NOW()`,
	}, rows)
}

func busDisplayStopRows(routes []rawBusDisplayStopOfRoute) [][]any {
	var rows [][]any
	for _, route := range routes {
		rows = append(rows, busDisplayRouteRows(route)...)
	}
	return rows
}

func busDisplayRouteRows(route rawBusDisplayStopOfRoute) [][]any {
	var rows [][]any
	for _, stop := range route.Stops {
		if !validBusDisplayStop(stop.StopUID, stop.StationID, stop.StopName.Zhtw, stop.StopSequence) {
			continue
		}
		rows = append(rows, []any{
			route.RouteUID, int16(route.Direction), stop.StopUID,
			int16(stop.StopSequence), stop.StationID, stop.StopName.Zhtw,
		})
	}
	return rows
}

func validBusDisplayStop(uid, stationID, name string, sequence uint8) bool {
	return uid != "" && stationID != "" && name != "" && sequence != 0
}
