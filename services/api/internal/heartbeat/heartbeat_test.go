package heartbeat

import (
	"context"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

const testIdle = 20 * time.Millisecond

type recordingStream struct {
	grpc.ServerStream
	ctx  context.Context
	mu   sync.Mutex
	sent []any
}

func (r *recordingStream) Context() context.Context { return r.ctx }

func (r *recordingStream) SendMsg(m any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, m)
	return nil
}

func (r *recordingStream) markers() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, m := range r.sent {
		if isMarker(m) {
			n++
		}
	}
	return n
}

func (r *recordingStream) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.sent)
}

func isMarker(m any) bool {
	msg, ok := m.(proto.Message)
	if !ok {
		return false
	}
	b, err := proto.Marshal(msg)
	return err == nil && len(b) > 0 && proto.Equal(msg, Marker())
}

var serverStream = &grpc.StreamServerInfo{IsServerStream: true}

func run(t *testing.T, info *grpc.StreamServerInfo, handler grpc.StreamHandler) *recordingStream {
	t.Helper()
	rs := &recordingStream{ctx: t.Context()}
	if err := StreamInterceptor(testIdle)(nil, rs, info, handler); err != nil {
		t.Fatal(err)
	}
	return rs
}

func TestIdleServerStreamGetsMarker(t *testing.T) {
	rs := run(t, serverStream, func(any, grpc.ServerStream) error {
		time.Sleep(5 * testIdle)
		return nil
	})
	if rs.markers() == 0 {
		t.Fatal("an idle server stream got no heartbeat")
	}
}

func TestDataPostponesMarker(t *testing.T) {
	rs := run(t, serverStream, func(_ any, ss grpc.ServerStream) error {
		for range 20 {
			if err := ss.SendMsg(&pb.Resp_BikeEta{}); err != nil {
				return err
			}
			time.Sleep(testIdle / 4)
		}
		return nil
	})
	if n := rs.markers(); n != 0 {
		t.Fatalf("a stream sending every %v got %d heartbeats", testIdle/4, n)
	}
}

func TestNothingSentAfterHandlerReturns(t *testing.T) {
	rs := run(t, serverStream, func(any, grpc.ServerStream) error {
		time.Sleep(2 * testIdle)
		return nil
	})
	before := rs.count()
	time.Sleep(4 * testIdle)
	if after := rs.count(); after != before {
		t.Fatalf("sent %d frames after the handler returned", after-before)
	}
}

func TestClientStreamsAreLeftAlone(t *testing.T) {
	rs := run(t, &grpc.StreamServerInfo{IsClientStream: true}, func(_ any, ss grpc.ServerStream) error {
		if _, wrapped := ss.(*stream); wrapped {
			t.Error("client-only stream was wrapped")
		}
		time.Sleep(4 * testIdle)
		return nil
	})
	if rs.count() != 0 {
		t.Fatal("client-only stream got a heartbeat")
	}
}

func TestCancelledStreamStopsBeating(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	rs := &recordingStream{ctx: ctx}
	cancel()
	err := StreamInterceptor(testIdle)(nil, rs, serverStream, func(any, grpc.ServerStream) error {
		time.Sleep(4 * testIdle)
		return nil
	})
	if err != nil || rs.count() != 0 {
		t.Fatalf("cancelled stream: err %v, sent %d", err, rs.count())
	}
}

// TestMarkerDecodesAsUnknownField pins the wire contract the app relies on:
// the frame decodes into any streaming response as field MarkerField = 1 and
// nothing else.
func TestMarkerDecodesAsUnknownField(t *testing.T) {
	b, err := proto.Marshal(Marker())
	if err != nil {
		t.Fatal(err)
	}
	num, typ, n := protowire.ConsumeTag(b)
	v, m := protowire.ConsumeVarint(b[n:])
	if num != MarkerField || typ != protowire.VarintType || v != 1 || n+m != len(b) {
		t.Fatalf("marker bytes %x = field %d type %d value %d", b, num, typ, v)
	}
	var resp pb.RespNear
	if err := proto.Unmarshal(b, &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.ProtoReflect().GetUnknown()) != len(b) || len(resp.NearBusStations) != 0 {
		t.Fatalf("marker decoded as %v", &resp)
	}
}
