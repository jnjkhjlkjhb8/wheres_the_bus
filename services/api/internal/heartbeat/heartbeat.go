// Package heartbeat keeps idle server streams alive through Cloudflare, which
// cuts a proxied gRPC stream after ~100s without a DATA frame. HTTP/2 PINGs end
// at the edge and do not count.
package heartbeat

import (
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/types/known/emptypb"
)

// MarkerField is the field number a heartbeat frame sets. Every
// server-streaming response message reserves it in models/*.proto, so a
// client decodes the frame as an otherwise empty message carrying this one
// unknown field and drops it. A plain empty frame would not do: near and
// alert streams legitimately send empty messages.
const MarkerField = 1000

// Idle is how long a stream may go without a frame before a heartbeat is
// sent; with the ticker check the longest silence is about twice this, well
// under Cloudflare's cut.
const Idle = 30 * time.Second

// Marker returns the heartbeat frame. grpc-go marshals whatever SendMsg is
// given, so one message serves every response type.
func Marker() *emptypb.Empty {
	m := &emptypb.Empty{}
	b := protowire.AppendTag(nil, MarkerField, protowire.VarintType)
	m.ProtoReflect().SetUnknown(protowire.AppendVarint(b, 1))
	return m
}

// StreamInterceptor sends Marker on server streams that stay silent for idle.
func StreamInterceptor(idle time.Duration) grpc.StreamServerInterceptor {
	marker := Marker()
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if !info.IsServerStream {
			return handler(srv, ss)
		}
		hs := &stream{ServerStream: ss, last: time.Now()}
		stop := hs.keepAlive(idle, marker)
		defer stop()
		return handler(srv, hs)
	}
}

// stream serializes SendMsg: the handler and the heartbeat goroutine share one
// ServerStream, and grpc-go forbids concurrent sends on it.
type stream struct {
	grpc.ServerStream
	mu   sync.Mutex
	last time.Time
}

func (s *stream) SendMsg(m any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.last = time.Now()
	return s.ServerStream.SendMsg(m)
}

// beat sends the marker if nothing went out for idle. A failed send is left to
// the handler, which sees the same broken stream on its next call.
func (s *stream) beat(idle time.Duration, marker any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.last) < idle {
		return
	}
	s.last = time.Now()
	_ = s.ServerStream.SendMsg(marker)
}

// keepAlive starts the heartbeat loop and returns a func that stops it and
// waits, so no frame is sent after the handler has returned.
func (s *stream) keepAlive(idle time.Duration, marker any) func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Go(func() {
		ticker := time.NewTicker(idle)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-s.Context().Done():
				return
			case <-ticker.C:
				s.beat(idle, marker)
			}
		}
	})
	return func() {
		close(done)
		wg.Wait()
	}
}
