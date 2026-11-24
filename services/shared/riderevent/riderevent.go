// Package riderevent carries bus arrival events from realtime, which computes
// them, to rider, which matches them against reminders and sends the pushes
// (ADR-0026). Events travel on a Redis stream read through a consumer group,
// so an event a rider-worker crashed on is reclaimed rather than lost.
package riderevent

import (
	"context"
	"encoding/json"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/samber/oops"
)

const (
	// StreamKey holds the arrival events.
	StreamKey = "rider:arrivals"
	// Group is the consumer group every rider-worker reads through.
	Group = "rider-worker"
	// MaxAge is how old an event may be and still be dispatched: an arrival two
	// minutes stale has already happened. The stream is trimmed to this age.
	// A cap by entry count did not bound memory, because one entry is a whole
	// city's batch, several megabytes for Taipei.
	MaxAge = 2 * time.Minute

	_fieldEvents = "events"
	_fieldAt     = "at"
)

var _oops = oops.In("riderevent")

// ArrivalEvent is one vehicle's predicted arrival at one stop.
type ArrivalEvent struct {
	RouteType     string `json:"route_type"`
	RouteKey      string `json:"route_key"`
	StopKey       string `json:"stop_key"`
	Direction     string `json:"direction"`
	ETASeconds    int32  `json:"eta_seconds"`
	ArrivingPlate string `json:"arriving_plate"`
}

// Publisher appends arrival batches to the stream.
type Publisher struct {
	RC  *redis.Client
	Now func() time.Time
}

// Arrivals publishes one batch as one stream entry. An empty batch is not
// published.
func (p Publisher) Arrivals(ctx context.Context, events []ArrivalEvent) error {
	if len(events) == 0 {
		return nil
	}
	body, err := json.Marshal(events)
	if err != nil {
		return _oops.Wrapf(err, "encode arrival events")
	}
	return p.publishArrivalBatch(ctx, body)
}

func (p Publisher) publishArrivalBatch(ctx context.Context, body []byte) error {
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	at := now()
	err := p.RC.XAdd(ctx, &redis.XAddArgs{
		Stream: StreamKey,
		MinID:  strconv.FormatInt(at.Add(-MaxAge).UnixMilli(), 10),
		Values: map[string]any{_fieldEvents: body, _fieldAt: at.UnixMilli()},
	}).Err()
	if err != nil {
		return _oops.Wrapf(err, "publish arrival events")
	}
	return nil
}

// Decode reads one stream entry back into its batch and the time it was
// published.
func Decode(msg redis.XMessage) ([]ArrivalEvent, time.Time, error) {
	body, _ := msg.Values[_fieldEvents].(string)
	var events []ArrivalEvent
	if err := json.Unmarshal([]byte(body), &events); err != nil {
		return nil, time.Time{}, _oops.With("id", msg.ID).Wrapf(err, "decode arrival events")
	}
	atRaw, _ := msg.Values[_fieldAt].(string)
	at, err := strconv.ParseInt(atRaw, 10, 64)
	if err != nil {
		return nil, time.Time{}, _oops.With("id", msg.ID).Wrapf(err, "decode arrival time")
	}
	return events, time.UnixMilli(at), nil
}
