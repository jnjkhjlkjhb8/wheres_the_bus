package nearby

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/go-resty/resty/v2"
)

const (
	_motisOneToManyPath      = "/api/v1/one-to-many"
	_motisWalkMaxSeconds     = 1800
	_motisWalkMatchingMeters = 100
)

// motisWalkingRouter answers the same question the OSRM table service did, so
// the compiler is told it still satisfies the interface nearby depends on.
var _ walkingRouter = (*motisWalkingRouter)(nil)

type motisWalkingRouter struct {
	client  *resty.Client
	baseURL string
}

func NewMotisWalkingRouter(client *resty.Client, baseURL string) *motisWalkingRouter {
	return &motisWalkingRouter{client: client, baseURL: strings.TrimRight(baseURL, "/")}
}

type motisOneToManyRequest struct {
	One                 string   `json:"one"`
	Many                []string `json:"many"`
	Mode                string   `json:"mode"`
	Max                 float64  `json:"max"`
	MaxMatchingDistance float64  `json:"maxMatchingDistance"`
	ArriveBy            bool     `json:"arriveBy"`
	WithDistance        bool     `json:"withDistance"`
}

type motisDuration struct {
	Duration *float64 `json:"duration"`
	Distance *float64 `json:"distance"`
}

func (r *motisWalkingRouter) RouteMany(
	ctx context.Context,
	origin GeoPoint,
	destinations []GeoPoint,
) ([]WalkingMetric, error) {
	if len(destinations) == 0 {
		return nil, nil
	}
	if r == nil || r.client == nil {
		return nil, errors.New("MOTIS client unavailable")
	}

	many := make([]string, 0, len(destinations))
	for _, point := range destinations {
		many = append(many, formatMotisCoordinate(point))
	}

	var result []motisDuration
	response, err := r.client.R().
		SetContext(ctx).
		SetHeader("Content-Type", "application/json").
		SetBody(motisOneToManyRequest{
			One:                 formatMotisCoordinate(origin),
			Many:                many,
			Mode:                "WALK",
			Max:                 _motisWalkMaxSeconds,
			MaxMatchingDistance: _motisWalkMatchingMeters,
			// One rider walking out to many stops, not many walking in.
			ArriveBy:     false,
			WithDistance: true,
		}).
		SetResult(&result).
		Post(r.baseURL + _motisOneToManyPath)
	if err != nil {
		return nil, _oops.Wrapf(err, "MOTIS one-to-many")
	}
	if !response.IsSuccess() {
		return nil, _oops.
			With("status_code", response.StatusCode()).
			With("destinations", len(destinations)).
			Errorf("MOTIS one-to-many HTTP")
	}
	// A short array would silently pair a stop with another stop's walking
	// time. Length is the only thing tying the two lists together, so it is
	// checked rather than assumed.
	if len(result) != len(destinations) {
		return nil, _oops.
			With("destinations", len(destinations)).
			With("durations", len(result)).
			Errorf("MOTIS one-to-many length mismatch")
	}

	metrics := make([]WalkingMetric, len(destinations))
	for i, entry := range result {
		metrics[i].DurationSeconds = entry.Duration
		metrics[i].DistanceMeters = entry.Distance
	}
	return metrics, nil
}

// formatMotisCoordinate renders a point the way one-to-many reads it:
// semicolon between latitude and longitude, because the comma separates one
// location from the next.
func formatMotisCoordinate(point GeoPoint) string {
	return fmt.Sprintf("%f;%f", point.Lat, point.Lon)
}
