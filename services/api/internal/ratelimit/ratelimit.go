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
	r.cleanupExpired(now)
	key := scope + "\x00" + caller
	bucket := r.bucketForWindow(key, now, window)
	r.scheduleCleanup(bucket.expiresAt)
	if bucket.count >= limit {
		return false
	}
	bucket.count++
	r.buckets[key] = bucket
	return true
}

func (r *Limiter) bucketForWindow(key string, now time.Time, window time.Duration) rateBucket {
	bucket, ok := r.buckets[key]
	if !ok || !now.Before(bucket.expiresAt) {
		return rateBucket{expiresAt: now.Add(window)}
	}
	return bucket
}

func (r *Limiter) scheduleCleanup(expiry time.Time) {
	if r.nextCleanup.IsZero() || expiry.Before(r.nextCleanup) {
		r.nextCleanup = expiry
	}
}

// The caller holds r.mu so expiry and the next request share one window.
func (r *Limiter) cleanupExpired(now time.Time) {
	if r.cleanupDue(now) {
		r.nextCleanup = time.Time{}
		for key, bucket := range r.buckets {
			if !now.Before(bucket.expiresAt) {
				delete(r.buckets, key)
				continue
			}
			r.scheduleCleanup(bucket.expiresAt)
		}
	}
}

func (r *Limiter) cleanupDue(now time.Time) bool {
	return r.nextCleanup.IsZero() || !now.Before(r.nextCleanup)
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
	return rl.Allow(scope, hostAddress(addr), limit, window)
}

func callerAddress(ctx context.Context, p *peer.Peer, trusted []netip.Prefix) string {
	host := hostAddress(p.Addr.String())
	if !trustedPeer(host, trusted) {
		return host
	}
	values := metadata.ValueFromIncomingContext(ctx, "x-forwarded-for")
	if len(values) != 1 {
		return host
	}
	return forwardedCaller(values[0], trusted, host)
}

func hostAddress(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return host
}

func trustedPeer(host string, trusted []netip.Prefix) bool {
	peerIP, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	return isTrustedProxy(peerIP, trusted)
}

func forwardedCaller(value string, trusted []netip.Prefix, host string) string {
	addresses, valid := forwardedAddresses(value)
	if !valid {
		return host
	}
	for i := len(addresses) - 1; i >= 0; i-- {
		if !isTrustedProxy(addresses[i], trusted) {
			return addresses[i].String()
		}
	}
	return host
}

func forwardedAddresses(value string) ([]netip.Addr, bool) {
	parts := strings.Split(value, ",")
	addresses := make([]netip.Addr, len(parts))
	for i, part := range parts {
		parsed, parseErr := netip.ParseAddr(strings.TrimSpace(part))
		if parseErr != nil {
			return nil, false
		}
		addresses[i] = parsed.Unmap()
	}
	return addresses, true
}

func isTrustedProxy(address netip.Addr, trusted []netip.Prefix) bool {
	for _, prefix := range trusted {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}
