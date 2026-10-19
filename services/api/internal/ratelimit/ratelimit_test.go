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

func TestCallerAddressTrustBoundary(t *testing.T) {
	trusted := []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("fd00::/8")}
	tests := []struct {
		name    string
		peer    string
		headers []string
		want    string
	}{
		{"untrusted transport ignores forwarding", "203.0.113.9:1234", []string{"198.51.100.1"}, "203.0.113.9"},
		{"invalid transport ignores forwarding", "unix-socket", []string{"198.51.100.1"}, "unix-socket"},
		{"bare transport address", "10.0.0.2", []string{"198.51.100.1"}, "198.51.100.1"},
		{"missing header", "10.0.0.2:1234", nil, "10.0.0.2"},
		{"duplicate headers", "10.0.0.2:1234", []string{"198.51.100.1", "198.51.100.2"}, "10.0.0.2"},
		{"empty header", "10.0.0.2:1234", []string{""}, "10.0.0.2"},
		{"invalid left hop rejects whole chain", "10.0.0.2:1234", []string{"invalid, 198.51.100.1"}, "10.0.0.2"},
		{"all trusted hops fall back to transport", "10.0.0.2:1234", []string{"10.0.0.3, 10.0.0.4"}, "10.0.0.2"},
		{"rightmost untrusted hop", "10.0.0.2:1234", []string{"198.51.100.1, 203.0.113.2, 10.0.0.3"}, "203.0.113.2"},
		{"whitespace and mapped addresses", "10.0.0.2:1234", []string{" ::ffff:198.51.100.1 , ::ffff:10.0.0.3 "}, "198.51.100.1"},
		{"ipv6 transport and client", "[fd00::2]:1234", []string{"2001:db8::1, fd00::3"}, "2001:db8::1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := metadata.NewIncomingContext(t.Context(), metadata.MD{"x-forwarded-for": tt.headers})
			got := callerAddress(ctx, &peer.Peer{Addr: limiterTestAddr(tt.peer)}, trusted)
			if got != tt.want {
				t.Fatalf("caller = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestCallerAddressWithoutTrustedProxies(t *testing.T) {
	ctx := metadata.NewIncomingContext(t.Context(), metadata.Pairs("x-forwarded-for", "198.51.100.1"))
	got := callerAddress(ctx, &peer.Peer{Addr: limiterTestAddr("10.0.0.2:1234")}, nil)
	if got != "10.0.0.2" {
		t.Fatalf("caller = %q, want transport peer", got)
	}
}

func TestRateLimiterWindowBoundaryAndScopes(t *testing.T) {
	rl := New()
	now := time.Unix(1_800_000_000, 0)
	rl.now = func() time.Time { return now }
	for i := range 2 {
		if !rl.Allow("a", "caller", 2, time.Second) {
			t.Fatalf("quota denied request %d before it was exhausted", i+1)
		}
	}
	if rl.Allow("a", "caller", 2, time.Second) {
		t.Fatal("quota allowed a third request")
	}
	if !rl.Allow("b", "caller", 1, time.Second) || !rl.Allow("a", "other", 1, time.Second) {
		t.Fatal("scope or caller inherited another quota")
	}
	now = now.Add(time.Second - time.Nanosecond)
	if rl.Allow("a", "caller", 2, time.Second) {
		t.Fatal("window expired early")
	}
	now = now.Add(time.Nanosecond)
	if !rl.Allow("a", "caller", 2, time.Second) {
		t.Fatal("window did not reset at its exact boundary")
	}
	if got := len(rl.buckets); got != 1 {
		t.Fatalf("retained %d buckets after all old windows expired", got)
	}
}

func TestAllowWithoutTransportIdentity(t *testing.T) {
	contexts := []context.Context{
		t.Context(),
		peer.NewContext(t.Context(), &peer.Peer{}),
		limiterContext(""),
	}
	for _, ctx := range contexts {
		if !Allow(ctx, New(), "scope", 0, time.Minute) {
			t.Fatal("request without a caller identity was denied")
		}
	}
}

type limiterServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s limiterServerStream) Context() context.Context { return s.ctx }

func TestStreamInterceptorEnforcesQuota(t *testing.T) {
	ctx := limiterContext("203.0.113.1:1234")
	stream := limiterServerStream{ctx: ctx}
	interceptor := StreamInterceptor(New(), 1, time.Minute)
	info := &grpc.StreamServerInfo{FullMethod: "/Service/Stream"}
	calls := 0
	handler := func(srv any, ss grpc.ServerStream) error {
		calls++
		if srv != "server" || ss.Context() != ctx {
			t.Fatal("handler arguments changed")
		}
		return status.Error(codes.Aborted, "handler error")
	}
	if err := interceptor("server", stream, info, handler); status.Code(err) != codes.Aborted {
		t.Fatalf("first request lost handler error: %v", err)
	}
	if err := interceptor("server", stream, info, handler); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("second request was not limited: %v", err)
	}
	if calls != 1 {
		t.Fatalf("handler calls = %d, want 1", calls)
	}
}

func TestTrustedProxyConfigurationIsCopied(t *testing.T) {
	proxies := []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")}
	rl := NewWithTrustedProxies(proxies)
	proxies[0] = netip.MustParsePrefix("192.168.0.0/16")
	ctx := metadata.NewIncomingContext(limiterContext("10.0.0.2:1234"), metadata.Pairs("x-forwarded-for", "198.51.100.1"))
	if !Allow(ctx, rl, "scope", 1, time.Minute) {
		t.Fatal("first client denied")
	}
	other := metadata.NewIncomingContext(limiterContext("10.0.0.2:1234"), metadata.Pairs("x-forwarded-for", "198.51.100.2"))
	if !Allow(other, rl, "scope", 1, time.Minute) {
		t.Fatal("mutating configuration changed the trusted transport policy")
	}
}
