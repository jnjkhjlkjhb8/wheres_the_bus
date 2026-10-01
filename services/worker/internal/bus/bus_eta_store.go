package bus

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/predict"
	"go.uber.org/zap"
)

type busEtaStore interface {
	staticStops(context.Context, string) ([]busmodel.StationMap, error)
	nextDepartures(context.Context, []predict.RouteDirKey, string, int) map[predict.RouteDirKey]time.Time
	stopOffsets(context.Context, []string) map[predict.StopOffsetKey]int
	saveHistory(context.Context, [][]any)
	saveStopEvents(context.Context, [][]any)
	recordPredictions(context.Context, []history.PredictionRecord)
}

type pgBusEtaStore struct {
	db *pgxpool.Pool
}

func (s pgBusEtaStore) staticStops(ctx context.Context, prefix string) ([]busmodel.StationMap, error) {
	return busstaticmp(ctx, s.db, prefix)
}

func (s pgBusEtaStore) nextDepartures(ctx context.Context, keys []predict.RouteDirKey, todTime string, dayBit int) map[predict.RouteDirKey]time.Time {
	return predict.BatchNextDepartures(ctx, s.db, keys, todTime, dayBit)
}

func (s pgBusEtaStore) stopOffsets(ctx context.Context, uids []string) map[predict.StopOffsetKey]int {
	return predict.BatchStopOffsets(ctx, s.db, uids)
}

// The caller's context is deliberately unused: it is the live tick's, and
// outliving it is the whole point (see history.Submit).
func (s pgBusEtaStore) saveHistory(_ context.Context, rows [][]any) {
	if len(rows) == 0 {
		return
	}
	target := history.Target()
	history.Submit("bus_eta_history", len(rows), func(ctx context.Context) {
		history.SaveBusEtaHistory(ctx, target, rows)
	})
}

func (s pgBusEtaStore) saveStopEvents(_ context.Context, rows [][]any) {
	if len(rows) == 0 {
		return
	}
	target := history.Target()
	history.Submit("bus_stop_event", len(rows), func(ctx context.Context) {
		history.SaveBusStopEvents(ctx, target, rows)
	})
}

func (s pgBusEtaStore) recordPredictions(_ context.Context, rows []history.PredictionRecord) {
	if len(rows) == 0 {
		return
	}
	db := s.db
	history.Submit("bus_eta_prediction_error", len(rows), func(ctx context.Context) {
		history.RecordPredictionErrors(ctx, db, rows)
	})
}

func busstaticmp(ctx context.Context, db *pgxpool.Pool, city string) ([]busmodel.StationMap, error) {
	query := `SELECT bssm.station_id, bssm.station_name,
	                 COALESCE(bsgm.group_uid, bssm.station_id),
	                 COALESCE(bg.group_name, bssm.station_name),
	                 bssm.sub_route_uid, COALESCE(bst.route_uid, ''), bssm.route_name,
	                 COALESCE(bsr.destin, bst.destin, ''),
	                 bssm.direction, bssm.stop_uid, bssm.stop_sequence,
	                 COALESCE(ST_Y(bs.position), 0), COALESCE(ST_X(bs.position), 0),
	                 COALESCE(alias.uids, ARRAY[]::text[])
	          FROM bus_station_stop_map bssm
	          LEFT JOIN LATERAL (
	            SELECT array_agg(a.alias_stop_uid) AS uids
	            FROM bus_stop_alias a
	            WHERE a.sub_route_uid = bssm.sub_route_uid
	              AND a.direction = bssm.direction
	              AND a.stop_uid = bssm.stop_uid
	          ) alias ON true
	          LEFT JOIN bus_static bst ON bst.sub_route_uid = bssm.sub_route_uid
	          LEFT JOIN bus_subroutes bsr ON bsr.sub_route_uid = bssm.sub_route_uid
	                                     AND bsr.direction = bssm.direction
	          LEFT JOIN bus_stations bs ON bs.station_uid = bssm.station_id
	          LEFT JOIN bus_station_group_members bsgm ON bsgm.station_uid = bssm.station_id
	          LEFT JOIN bus_station_groups bg ON bg.group_uid = bsgm.group_uid
	          WHERE bssm.sub_route_uid LIKE $1`
	rows, err := db.Query(ctx, query, city+"%")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []busmodel.StationMap
	for rows.Next() {
		var temp busmodel.StationMap
		err := rows.Scan(&temp.StationUID, &temp.StationName, &temp.GroupUID,
			&temp.GroupName, &temp.SubRouteUID, &temp.RouteUID, &temp.SubRouteName, &temp.Destination, &temp.Direction, &temp.StopUID, &temp.StopSequence,
			&temp.Lat, &temp.Lon, &temp.AliasStopUIDs)
		if err != nil {
			zap.S().Errorw("scan error",
				"component", "bus_static",
				"action", "station_map",
				"event", "scan_error",
				"err", err,
			)
			continue
		}
		list = append(list, temp)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return list, nil
}
