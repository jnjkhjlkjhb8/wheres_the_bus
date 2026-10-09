package ratelimit

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

type limiterTestAddr string

func (a limiterTestAddr) Network() string { return "tcp" }
func (a limiterTestAddr) String() string  { return string(a) }

func limiterContext(address string) context.Context {
	return peer.NewContext(context.Background(), &peer.Peer{Addr: limiterTestAddr(address)})
}

func TestForwardedCallerUsesRightmostUntrustedHop(t *testing.T) {
	rl := NewWithTrustedProxies([]netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")})
	ctx := peer.NewContext(context.Background(), &peer.Peer{Addr: limiterTestAddr("10.0.0.2:443")})
	ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("x-forwarded-for", "198.51.100.9, 203.0.113.7"))
	if !Allow(ctx, rl, "scope", 1, time.Minute) {
		t.Fatal("first caller denied")
	}
	spoof := metadata.NewIncomingContext(ctx, metadata.Pairs("x-forwarded-for", "192.0.2.55, 203.0.113.7"))
	if Allow(spoof, rl, "scope", 1, time.Minute) {
		t.Fatal("spoofed prefix changed caller identity")
	}
}

func TestRateLimiterExpiresBucketsIndependently(t *testing.T) {
	rl := New()
	now := time.Unix(1_800_000_000, 0)
	rl.now = func() time.Time { return now }
	interceptor := UnaryInterceptor(rl, 1, 80*time.Millisecond)
	handler := func(context.Context, any) (any, error) { return "ok", nil }
	info := &grpc.UnaryServerInfo{FullMethod: "/Service/A"}
	callerA := limiterContext(net.JoinHostPort("203.0.113.11", "1234"))
	callerB := limiterContext(net.JoinHostPort("203.0.113.12", "1234"))

	if _, err := interceptor(callerA, nil, info, handler); err != nil {
		t.Fatal(err)
	}
	now = now.Add(50 * time.Millisecond)
	if _, err := interceptor(callerB, nil, info, handler); err != nil {
		t.Fatal(err)
	}
	now = now.Add(45 * time.Millisecond)
	if _, err := interceptor(callerB, nil, info, handler); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("caller B bucket was reset by caller A expiry: code=%v", status.Code(err))
	}
	if got := len(rl.buckets); got != 1 {
		t.Fatalf("expired buckets after cleanup = %d, want only caller B", got)
	}
	if _, err := interceptor(callerA, nil, info, handler); err != nil {
		t.Fatalf("expired caller A bucket was not renewed: %v", err)
	}
}

func TestRateLimiterCleanupHonorsShortestBucketWindow(t *testing.T) {
	rl := New()
	now := time.Unix(1_800_000_000, 0)
	rl.now = func() time.Time { return now }
	if !rl.Allow("long", "caller", 1, time.Minute) || !rl.Allow("short", "caller", 1, time.Second) {
		t.Fatal("initial requests were denied")
	}
	now = now.Add(2 * time.Second)
	_ = rl.Allow("long", "caller", 1, time.Minute)
	if got := len(rl.buckets); got != 1 {
		t.Fatalf("expired short-window buckets after cleanup = %d, want only long-window bucket", got)
	}
}
