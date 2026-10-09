package history

import (
	"context"
	"math"
	"time"

	"go.uber.org/zap"
)

// Haversine returns the great-circle distance in meters between two lat/lon
// points, used to pick the nearest live vehicle to a stop.
func Haversine(lat1, lon1, lat2, lon2 float64) float64 {
	const R = 6371000
	φ1 := lat1 * math.Pi / 180
	φ2 := lat2 * math.Pi / 180
	dφ := (lat2 - lat1) * math.Pi / 180
	dλ := (lon2 - lon1) * math.Pi / 180
	a := math.Sin(dφ/2)*math.Sin(dφ/2) + math.Cos(φ1)*math.Cos(φ2)*math.Sin(dλ/2)*math.Sin(dλ/2)
	return 2 * R * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

var _busEtaHistoryCols = []string{
	"sub_route_uid", "stop_uid", "direction", "stop_sequence", "total_stops",
	"estimate", "next_bus_time", "src_update_time", "city", "hour", "day_of_week",
	"is_holiday", "temperature", "precipitation", "wind_speed", "humidity",
	"plate_numb", "bus_speed", "bus_distance_m", "recorded_at",
}

const (
	_historySnapshotInterval = 10 * time.Minute
	BusEtaTickInterval       = 30 * time.Second
	BusEtaFastTickInterval   = 20 * time.Second
)

func SnapshotTick(now time.Time, tickInterval time.Duration) bool {
	return now.Unix()%int64(_historySnapshotInterval.Seconds()) < int64(tickInterval.Seconds())
}

func RecordsHistory(estimate int32, snapshot bool) bool {
	return estimate <= 0 || snapshot
}

func SaveBusStopEvents(ctx context.Context, db Execer, rows [][]any) {
	if len(rows) == 0 {
		return
	}
	if err := Insert(ctx, db, "bus_stop_event", BusStopEventCols, rows); err != nil {
		zap.S().Errorw("insert error", "component", "bus_nearstop", "rows", len(rows), "err", err)
		return
	}
	zap.S().Infow("inserted rows", "component", "bus_nearstop", "rows", len(rows))
}

func SaveBusEtaHistory(ctx context.Context, db Execer, rows [][]any) {
	if len(rows) == 0 {
		return
	}
	if err := Insert(ctx, db, "bus_eta_history", _busEtaHistoryCols, rows); err != nil {
		zap.S().Errorw("insert error", "component", "eta_history", "rows", len(rows), "err", err)
		return
	}
	zap.S().Infow("inserted rows", "component", "eta_history", "rows", len(rows))
}
