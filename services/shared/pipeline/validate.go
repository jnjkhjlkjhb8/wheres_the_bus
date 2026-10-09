package pipeline

import (
	"context"
	"math"
	"time"
)

type LoadSource interface {
	DatasetJSON(ctx context.Context, table, partCol, partVal string) ([]byte, time.Time, error)
}

func ValidClock(value string) bool {
	_, err := time.Parse("15:04", value)
	return err == nil
}

func ValidPosition(lon, lat float64) bool {
	return !math.IsNaN(lon) && !math.IsNaN(lat) && !math.IsInf(lon, 0) && !math.IsInf(lat, 0) && lon >= -180 && lon <= 180 && lat >= -90 && lat <= 90 && (lon != 0 || lat != 0)
}
