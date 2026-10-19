package rail

import (
	"testing"
	"time"
)

func TestTHSRTravelDuration(t *testing.T) {
	tests := []struct {
		name      string
		departure string
		arrival   string
		want      time.Duration
	}{
		{"same day", "09:00:00", "10:15:00", 75 * time.Minute},
		{"overnight", "23:30:00", "00:15:00", 45 * time.Minute},
		{"equal instants", "09:00:00", "09:00:00", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := thsrTravelDuration(tt.departure, tt.arrival)
			if !ok || got != tt.want {
				t.Fatalf("duration = %v, valid %v, want %v", got, ok, tt.want)
			}
		})
	}
}

func TestTHSRTravelDurationRejectsMalformedTimes(t *testing.T) {
	for _, times := range [][2]string{{"invalid", "10:00:00"}, {"09:00:00", "invalid"}, {"24:00:00", "10:00:00"}} {
		if _, ok := thsrTravelDuration(times[0], times[1]); ok {
			t.Fatalf("malformed journey %v accepted", times)
		}
	}
}
