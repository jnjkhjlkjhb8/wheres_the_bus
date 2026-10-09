package shared

import (
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestConnectRedis_WithPassword(t *testing.T) {
	addr := envOrSkip(t, "REDIS_AUTH_TEST_ADDR")
	password := envOrSkip(t, "REDIS_AUTH_TEST_PASSWORD")

	client := redis.NewClient(&redis.Options{Addr: addr, Password: password})
	t.Cleanup(func() { _ = client.Close() })

	deadline := time.Now().Add(5 * time.Second)
	var pong string
	var err error
	for {
		pong, err = client.Ping(t.Context()).Result()
		if err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("PING against password-protected Redis failed: %v", err)
	}
	if pong != "PONG" {
		t.Fatalf("PING reply = %q, want PONG", pong)
	}

	// A client that sends the wrong password must be rejected — proves the
	// server actually enforces requirepass rather than the test dialing an
	// unauthenticated Redis by accident.
	wrong := redis.NewClient(&redis.Options{Addr: addr, Password: "definitely-not-the-password"})
	t.Cleanup(func() { _ = wrong.Close() })
	if _, err := wrong.Ping(t.Context()).Result(); err == nil {
		t.Fatal("PING with wrong password unexpectedly succeeded")
	}
}

func envOrSkip(t *testing.T, name string) string {
	t.Helper()
	v := os.Getenv(name)
	if v == "" {
		t.Skipf("%s not set", name)
	}
	return v
}
