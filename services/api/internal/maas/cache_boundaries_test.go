package maas

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/go-resty/resty/v2"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestMaasWorkConfigurationPreservesPositiveLimitsAndDefaultsNonpositive(t *testing.T) {
	for _, tc := range []struct {
		name    string
		config  maasSharedWorkConfig
		limit   int
		timeout time.Duration
	}{
		{"zero", maasSharedWorkConfig{}, 4, 20 * time.Second},
		{"negative", maasSharedWorkConfig{MaxConcurrent: -1, Timeout: -time.Second}, 4, 20 * time.Second},
		{"smallest positive", maasSharedWorkConfig{MaxConcurrent: 1, Timeout: time.Nanosecond}, 1, time.Nanosecond},
		{"custom", maasSharedWorkConfig{MaxConcurrent: 2, Timeout: 3 * time.Second}, 2, 3 * time.Second},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
			server := NewMaasServerWithCache(newControlledMaasCache(), nil, tdx, tc.config)
			defer server.Close()
			if server.workTimeout != tc.timeout {
				t.Fatalf("work timeout = %v, want %v", server.workTimeout, tc.timeout)
			}
			for range tc.limit {
				release, err := server.acquireWorkSlot()
				if err != nil {
					t.Fatal(err)
				}
				defer release()
			}
			if _, err := server.acquireWorkSlot(); status.Code(err) != codes.ResourceExhausted {
				t.Fatalf("exhausted work limit error = %v", err)
			}
		})
	}
}

func TestMaasRetryPolicyOnlyRetriesTransientUpstreamFailures(t *testing.T) {
	for _, code := range []int{200, 400, 404, 429, 500, 503} {
		response := &resty.Response{RawResponse: &http.Response{StatusCode: code}}
		if got, want := shouldRetryMaas(response, nil), code == 429 || code == 503; got != want {
			t.Errorf("retry HTTP %d = %v, want %v", code, got, want)
		}
	}
	for _, tc := range []struct {
		err  error
		want bool
	}{
		{errors.New("connection reset"), true},
		{fmt.Errorf("wrapped: %w", context.Canceled), false},
		{fmt.Errorf("wrapped: %w", context.DeadlineExceeded), false},
		{&shared.TDXAuthError{Err: errors.New("token unavailable")}, false},
	} {
		if got := shouldRetryMaas(nil, tc.err); got != tc.want {
			t.Errorf("retry %v = %v", tc.err, got)
		}
	}
	if shouldRetryMaas(nil, nil) {
		t.Fatal("nil response requested retry")
	}
}

func TestRedisMaasCacheStoresCompletedPlanForNinetySeconds(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	cache := NewRedisMaasCache(&redis.Options{Addr: addr})
	t.Cleanup(func() { _ = cache.Close() })
	key := fmt.Sprintf("quality:maas:%d", os.Getpid())
	t.Cleanup(func() { _ = cache.client.Del(context.Background(), key).Err() })
	if _, err := cache.Get(t.Context(), key); !errors.Is(err, redis.Nil) {
		t.Fatalf("missing cache error = %v", err)
	}
	server := &MaasServer{cache: cache}
	want := &pb.MaasPlanResponse{NextPageCursor: "next", PreviousPageCursor: "previous"}
	got, err := server.persistSharedPlan(t.Context(), key, want)
	if err != nil || !proto.Equal(got, want) {
		t.Fatalf("persisted plan = %v, error %v", got, err)
	}
	stored, ok := server.cachedPlan(t.Context(), key)
	if !ok || !proto.Equal(stored, want) {
		t.Fatalf("cached plan = %v, found %v", stored, ok)
	}
	if ttl, err := cache.client.PTTL(t.Context(), key).Result(); err != nil || ttl < 89*time.Second || ttl > 90*time.Second {
		t.Fatalf("plan TTL = %v, error %v", ttl, err)
	}
	if err := cache.Close(); err != nil {
		t.Fatal(err)
	}
	if err := cache.Set(t.Context(), key, []byte("bad"), time.Second); err == nil {
		t.Fatal("closed cache accepted write")
	}
}

func TestMaasInvalidStringDoesNotWriteAnInvalidCachedPlan(t *testing.T) {
	cache := newControlledMaasCache()
	server := &MaasServer{cache: cache}
	response := &pb.MaasPlanResponse{NextPageCursor: string([]byte{0xff})}
	server.cachePlan(t.Context(), "stream", response)
	got, err := server.persistSharedPlan(t.Context(), "shared", response)
	if err != nil || got != response {
		t.Fatalf("uncacheable response = %v, error %v", got, err)
	}
	if calls := cache.setCalls.Load(); calls != 0 {
		t.Fatalf("uncacheable response issued %d cache writes", calls)
	}
}
