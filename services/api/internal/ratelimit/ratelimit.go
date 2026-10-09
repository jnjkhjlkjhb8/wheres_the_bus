// Package ratelimit is the router's per-caller request quota: a fixed-window
// counter keyed by scope and caller, plus the gRPC interceptors that apply it.
// Buckets expire on their own window, so an idle caller costs no memory.
package ratelimit

// Per-caller request rate limiting, and the generic gRPC interceptors that
// spend from it. The buckets are in-process: the router runs as a single
// replica, so a shared store would add a dependency for no extra accuracy.

import (
	"context"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

type Limiter struct {
	mu             sync.Mutex
	buckets        map[string]rateBucket
	nextCleanup    time.Time
	now            func() time.Time
	trustedProxies []netip.Prefix
}

// NewWithTrustedProxies enables forwarding-aware caller keys. Forwarded
// headers are accepted only when the transport peer belongs to one of these
// explicitly configured proxy networks.
func NewWithTrustedProxies(proxies []netip.Prefix) *Limiter {
	r := New()
	r.trustedProxies = append([]netip.Prefix(nil), proxies...)
	return r
}

type rateBucket struct {
	count     int
	expiresAt time.Time
}

func New() *Limiter {
	return &Limiter{
		buckets: make(map[string]rateBucket, 128),
		now:     time.Now,
	}
}

func (r *Limiter) Allow(scope, caller string, limit int, window time.Duration) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	if r.nextCleanup.IsZero() || !now.Before(r.nextCleanup) {
		r.nextCleanup = time.Time{}
		for key, bucket := range r.buckets {
			if !now.Before(bucket.expiresAt) {
				delete(r.buckets, key)
				continue
			}
			if r.nextCleanup.IsZero() || bucket.expiresAt.Before(r.nextCleanup) {
				r.nextCleanup = bucket.expiresAt
			}
		}
	}
	key := scope + "\x00" + caller
	bucket, ok := r.buckets[key]
	if !ok || !now.Before(bucket.expiresAt) {
		bucket = rateBucket{expiresAt: now.Add(window)}
	}
	if r.nextCleanup.IsZero() || bucket.expiresAt.Before(r.nextCleanup) {
		r.nextCleanup = bucket.expiresAt
	}
	if bucket.count >= limit {
		return false
	}
	bucket.count++
	r.buckets[key] = bucket
	return true
}
func UnaryInterceptor(rl *Limiter, limit int, window time.Duration) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if !Allow(ctx, rl, info.FullMethod, limit, window) {
			return nil, status.Error(codes.ResourceExhausted, "rate limit exceeded")
		}
		return handler(ctx, req)
	}
}
func StreamInterceptor(rl *Limiter, limit int, window time.Duration) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if !Allow(ss.Context(), rl, info.FullMethod, limit, window) {
			return status.Error(codes.ResourceExhausted, "rate limit exceeded")
		}
		return handler(srv, ss)
	}
}
func Allow(ctx context.Context, rl *Limiter, scope string, limit int, window time.Duration) bool {
	peerInfo, ok := peer.FromContext(ctx)
	if !ok || peerInfo.Addr == nil {
		return true
	}
	addr := callerAddress(ctx, peerInfo, rl.trustedProxies)
	if addr == "" {
		return true
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	return rl.Allow(scope, host, limit, window)
}

func callerAddress(ctx context.Context, p *peer.Peer, trusted []netip.Prefix) string {
	addr := p.Addr.String()
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	peerIP, err := netip.ParseAddr(host)
	if err != nil || len(trusted) == 0 {
		return host
	}
	trustedPeer := false
	for _, prefix := range trusted {
		if prefix.Contains(peerIP) {
			trustedPeer = true
			break
		}
	}
	if !trustedPeer {
		return host
	}
	values := metadata.ValueFromIncomingContext(ctx, "x-forwarded-for")
	if len(values) != 1 {
		return host
	}
	parts := strings.Split(values[0], ",")
	addresses := make([]netip.Addr, len(parts))
	for i, part := range parts {
		parsed, parseErr := netip.ParseAddr(strings.TrimSpace(part))
		if parseErr != nil {
			return host
		}
		addresses[i] = parsed.Unmap()
	}
	for i := len(addresses) - 1; i >= 0; i-- {
		trustedHop := false
		for _, prefix := range trusted {
			if prefix.Contains(addresses[i]) {
				trustedHop = true
				break
			}
		}
		if !trustedHop {
			return addresses[i].String()
		}
	}
	return host
}
