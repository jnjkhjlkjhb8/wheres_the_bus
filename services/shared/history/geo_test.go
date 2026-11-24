package history

import (
	"math"
	"testing"
)

func TestHistoryNativeGreatCircleDistances(t *testing.T) {
	for _, tc := range []struct {
		name                          string
		lat1, lon1, lat2, lon2, angle float64
	}{
		{"meridian", 10, 0, 40, 0, math.Pi / 6},
		{"northern_parallel", 60, 0, 60, 180, math.Pi / 3},
		{"lower_parallel", 30, 0, 30, 180, 2 * math.Pi / 3},
		{"quarter_sphere", 0, 0, 60, 90, math.Pi / 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			want := 6371000 * tc.angle
			got := Haversine(tc.lat1, tc.lon1, tc.lat2, tc.lon2)
			if math.IsNaN(got) || math.Abs(got-want) > 0.000001 {
				t.Fatalf("great-circle distance = %.9f m, want %.9f m", got, want)
			}
		})
	}
}

func TestHaversineSamePointIsZero(t *testing.T) {
	if Haversine(25.0, 121.5, 25.0, 121.5) != 0 {
		t.Error("same point should be 0")
	}
}
