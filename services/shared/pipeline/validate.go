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
	return validCoordinate(lon, 180) && validCoordinate(lat, 90) && (lon != 0 || lat != 0)
}

func validCoordinate(value, limit float64) bool {
	return finiteCoordinate(value) && coordinateInBounds(value, limit)
}

func finiteCoordinate(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func coordinateInBounds(value, limit float64) bool { return value >= -limit && value <= limit }
