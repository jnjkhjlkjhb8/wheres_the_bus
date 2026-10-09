package transit

import (
	"context"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/redistest"
	redis "github.com/redis/go-redis/v9"
)

func contextGovernedRedisOptions(addr string) *redis.Options {
	return &redis.Options{
		Network: "tcp", Addr: addr,
		MaxRetries:  -1,
		DialTimeout: time.Second,
		// -1 disables the socket deadlines, so a parked server would hang this
		// call forever if cancellation were not wired through.
		ReadTimeout: -1, WriteTimeout: -1,
		PoolSize: 1, PoolTimeout: time.Second,
		Protocol:              2,
		ContextTimeoutEnabled: true,
	}
}

func TestDailyBoundsRedisReadByContextDeadline(t *testing.T) {
	endpoint := redistest.Start(t, "get")
	client := redis.NewClient(contextGovernedRedisOptions(endpoint.Address))
	defer func() { _ = client.Close() }()

	server := &BusRouteserver{rc: client}
	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()

	done := make(chan error, 1)
	go func() {
		_, err := server.Daily(ctx, &pb.Bus_Ask_Route{SubRouteUID: "KHH1"})
		done <- err
	}()

	select {
	case <-endpoint.CommandStarted:
	case err := <-done:
		t.Fatalf("Daily returned %v before the Redis read was even issued", err)
	case <-time.After(2 * time.Second):
		t.Fatal("Redis GET was never issued")
	}

	// The read is now parked server-side with the socket deadlines disabled, so
	// only the context deadline can end it.
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Daily returned a nil error for a read that was never answered")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the context deadline did not bound the Redis read: the request context is not reaching go-redis")
	}
}

// TestDailyFailsFastOnAlreadyCancelledContext covers the other half: a context
// that is already done before the call must not reach Redis at all.
func TestDailyFailsFastOnAlreadyCancelledContext(t *testing.T) {
	endpoint := redistest.Start(t, "get")
	client := redis.NewClient(contextGovernedRedisOptions(endpoint.Address))
	defer func() { _ = client.Close() }()

	server := &BusRouteserver{rc: client}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	done := make(chan error, 1)
	go func() {
		_, err := server.Daily(ctx, &pb.Bus_Ask_Route{SubRouteUID: "KHH1"})
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Daily returned a nil error for an already-cancelled context")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Daily blocked on Redis despite an already-cancelled context")
	}
}
