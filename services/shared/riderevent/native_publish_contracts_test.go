package riderevent

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestArrivalPublisherPreservesRedisWriteFailure(t *testing.T) {
	client := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	t.Cleanup(func() { _ = client.Close() })
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	publisher := Publisher{RC: client, Now: func() time.Time { return time.Unix(1760000000, 0) }}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := publisher.Arrivals(ctx, []ArrivalEvent{{RouteType: "bus", RouteKey: "TPE-native", StopKey: "stop", Direction: "1", ETASeconds: 30, ArrivingPlate: "ABC-123"}})
	if !errors.Is(err, redis.ErrClosed) {
		t.Fatalf("failed arrival publication lost Redis cause: %v", err)
	}
}
