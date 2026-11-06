package mrtsync

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
	"google.golang.org/protobuf/proto"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

// _busRouteOffline is one row per sub-route with both directions' stops as
// compact JSON (ADR-0029). It is built from the served pb rather than copied,
// so its stops are exactly what the router serves, turnaround splits included.
var _busRouteOffline = table{
	name: "bus_route_offline",
	key:  []string{"sub_route_uid"},
	data: []string{
		"city", "route_name", "sub_route_name", "depart", "destin",
		"headsign_go", "headsign_return", "stops_go", "stops_return",
	},
	read: readBusRoutes,
}

// readBusRoutes reads bus_static row by row: CollectRows keeps only each
// mapped slim row, not the pb, which is ~600 MB in all.
func readBusRoutes(ctx context.Context, src Source) ([][]any, error) {
	rows, err := src.Query(ctx, `SELECT pb FROM bus_static`)
	if err != nil {
		return nil, _oops.With("table", "bus_static").Wrapf(err, "read source")
	}
	out, err := pgx.CollectRows(rows, scanBusRoute)
	if err != nil {
		return nil, _oops.With("table", "bus_static").Wrapf(err, "scan source")
	}
	return out, nil
}

func scanBusRoute(r pgx.CollectableRow) ([]any, error) {
	var pb []byte
	if err := r.Scan(&pb); err != nil {
		return nil, err
	}
	return busRouteRow(pb)
}

// busRouteRow returns the row in _busRouteOffline.columns() order.
func busRouteRow(pb []byte) ([]any, error) {
	var sub models.BusSubroute
	if err := proto.Unmarshal(pb, &sub); err != nil {
		return nil, _oops.With("table", "bus_static").Wrapf(err, "decode pb")
	}
	goDir, returnDir := sub.GetDirections()[0], sub.GetDirections()[1]
	goStops, err := stopsJSON(goDir)
	if err != nil {
		return nil, _oops.With("sub_route_uid", sub.GetSubRouteUID()).Wrapf(err, "encode stops")
	}
	returnStops, err := stopsJSON(returnDir)
	if err != nil {
		return nil, _oops.With("sub_route_uid", sub.GetSubRouteUID()).Wrapf(err, "encode stops")
	}
	return []any{
		sub.GetSubRouteUID(), sub.GetCity(), sub.GetRouteName(), sub.GetSubRouteName(),
		sub.GetDepartureStopName(), sub.GetDestinationStopName(),
		goDir.GetDestinationStopName(), returnDir.GetDestinationStopName(),
		goStops, returnStops,
	}, nil
}

// stopsJSON encodes [stop_uid, stop_name, sequence, lat, lon] per stop. Arrays
// rather than objects keep the payload about half the size; the app decodes
// them by position. A NaN or infinite position fails the encode, and with it
// the sync, rather than shipping a stop list the app cannot parse.
func stopsJSON(dir *models.Direction) (string, error) {
	stops := make([][]any, 0, len(dir.GetStops()))
	for _, s := range dir.GetStops() {
		stops = append(stops, []any{s.GetStopUID(), s.GetStopName(), s.GetStopSequence(), s.GetPositionLat(), s.GetPositionLon()})
	}
	raw, err := json.Marshal(stops)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
