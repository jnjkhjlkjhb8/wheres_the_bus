package riderevent

import (
	"context"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	// WatchKey is a Redis set holding WatchMember of every reminder that could
	// still fire. rider-worker rewrites it; realtime publishes only the
	// arrivals in it. Without it every tick carried every stop in the city,
	// megabytes per batch with nobody to match them against.
	WatchKey = "rider:arrival_watch"
	// WatchTTL keeps the set through a rider-worker restart. If rider-worker
	// stays down longer, nothing would consume the events anyway.
	WatchTTL = 10 * time.Minute
)

// WatchMember is the identity a reminder and an arrival are matched on.
func WatchMember(routeType, routeKey, stopKey, direction string) string {
	return strings.Join([]string{routeType, routeKey, stopKey, direction}, "|")
}

func (e ArrivalEvent) watchMember() string {
	return WatchMember(e.RouteType, e.RouteKey, e.StopKey, e.Direction)
}

// StoreWatch replaces the watch set in one transaction. An empty list leaves
// no key, which publishes nothing.
func StoreWatch(ctx context.Context, rc redis.Cmdable, members []string) error {
	_, err := rc.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
		pipe.Del(ctx, WatchKey)
		if len(members) > 0 {
			pipe.SAdd(ctx, WatchKey, members)
			pipe.Expire(ctx, WatchKey, WatchTTL)
		}
		return nil
	})
	if err != nil {
		return _oops.Wrapf(err, "store arrival watch")
	}
	return nil
}

// Watched publishes only the arrivals some reminder is waiting on.
type Watched struct {
	Publisher Publisher
}

func (w Watched) Arrivals(ctx context.Context, events []ArrivalEvent) error {
	watched, err := w.Publisher.RC.SMembersMap(ctx, WatchKey).Result()
	if err != nil {
		return _oops.Wrapf(err, "read arrival watch")
	}
	return w.Publisher.Arrivals(ctx, watchedEvents(events, watched))
}

func watchedEvents(events []ArrivalEvent, watched map[string]struct{}) []ArrivalEvent {
	var out []ArrivalEvent
	for _, event := range events {
		if _, ok := watched[event.watchMember()]; ok {
			out = append(out, event)
		}
	}
	return out
}
