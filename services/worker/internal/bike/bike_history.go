package bike

import (
	"context"
	"sync"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"go.uber.org/zap"
)

const _bikeHistorySampleInterval = 5 * time.Minute

type bikeHistorySampler struct {
	mu   sync.Mutex
	last map[string]time.Time
}

func (s *bikeHistorySampler) shouldSample(stationUID string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.last == nil {
		s.last = make(map[string]time.Time)
	}
	prev, seen := s.last[stationUID]
	if seen && now.Sub(prev) < _bikeHistorySampleInterval {
		return false
	}
	s.last[stationUID] = now
	return true
}

// _bikeHistoryCols is the column order saveBikeAvailabilityHistory binds, and
// must match the row shape Eta builds.
var _bikeHistoryCols = []string{"station_uid", "available_rent", "available_return", "recorded_at"}

func saveBikeAvailabilityHistory(ctx context.Context, db history.Execer, rows [][]any) {
	if db == nil || len(rows) == 0 {
		return
	}
	if err := history.Insert(ctx, db, "bike_availability_history", _bikeHistoryCols, rows); err != nil {
		zap.S().Errorw("insert error", "component", "bike_history", "rows", len(rows), "err", err)
		return
	}
	zap.S().Infow("inserted rows", "component", "bike_history", "rows", len(rows))
}
