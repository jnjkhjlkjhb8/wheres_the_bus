package main

import (
	"context"
	"io"
	"net"
	"strings"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/stats"
	"google.golang.org/grpc/test/bufconn"
)

// Stands in for the verbatim TDX fare JSON a Bus_Fare carries. It is far more
// repetitive than real data, so the ratios these tests log mean nothing — the
// assertions are only that compression happened at all.
var _compressibleFare = strings.Repeat(`{"TicketType":1,"FareClass":1,"Price":145},`, 500)

const (
	_compressionUnaryMethod  = "/router.test.Fare/Get"
	_compressionStreamMethod = "/router.test.Fare/Watch"
	_compressionStreamFrames = 3
)

func TestServerMirrorsGzipFromClient(t *testing.T) {
	conn, seen := compressionTestConn(t)

	out := &pb.Bus_Fare{}
	if err := conn.Invoke(context.Background(), _compressionUnaryMethod, &pb.Bus_Fare{}, out, grpc.UseCompressor(gzip.Name)); err != nil {
		t.Fatalf("invoke: %v", err)
	}
	if string(out.SectionFaresJson) != _compressibleFare {
		t.Fatalf("payload round-tripped wrong: got %d bytes, want %d", len(out.SectionFaresJson), len(_compressibleFare))
	}
	assertCompressed(t, seen, 1)
}

func TestServerMirrorsGzipOnServerStream(t *testing.T) {
	conn, seen := compressionTestConn(t)

	stream, err := conn.NewStream(context.Background(),
		&grpc.StreamDesc{ServerStreams: true}, _compressionStreamMethod, grpc.UseCompressor(gzip.Name))
	if err != nil {
		t.Fatalf("new stream: %v", err)
	}
	if err := stream.SendMsg(&pb.Bus_Fare{}); err != nil {
		t.Fatalf("send: %v", err)
	}
	if err := stream.CloseSend(); err != nil {
		t.Fatalf("close send: %v", err)
	}
	for {
		out := &pb.Bus_Fare{}
		err := stream.RecvMsg(out)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("recv: %v", err)
		}
		if string(out.SectionFaresJson) != _compressibleFare {
			t.Fatalf("frame round-tripped wrong: got %d bytes, want %d", len(out.SectionFaresJson), len(_compressibleFare))
		}
	}
	assertCompressed(t, seen, _compressionStreamFrames)
}

func assertCompressed(t *testing.T, seen *payloadSizes, wantFrames int) {
	t.Helper()
	if seen.frames != wantFrames {
		t.Fatalf("stats handler saw %d response payloads, want %d", seen.frames, wantFrames)
	}
	if seen.compressed >= seen.uncompressed {
		t.Fatalf("responses were not compressed: wire %d bytes vs messages %d bytes — is encoding/gzip still imported in main.go?",
			seen.compressed, seen.uncompressed)
	}
	t.Logf("%d frame(s): %d bytes -> %d on the wire (%.1fx)",
		seen.frames, seen.uncompressed, seen.compressed, float64(seen.uncompressed)/float64(seen.compressed))
}

// compressionTestConn serves one unary and one server-streaming method off a
// bufconn, both replying with _compressibleFare, and returns a client wired to a
// stats handler that measures what arrives.
func compressionTestConn(t *testing.T) (*grpc.ClientConn, *payloadSizes) {
	t.Helper()
	reply := &pb.Bus_Fare{SectionFaresJson: []byte(_compressibleFare)}

	desc := &grpc.ServiceDesc{
		ServiceName: "router.test.Fare",
		HandlerType: (*any)(nil),
		Methods: []grpc.MethodDesc{{
			MethodName: "Get",
			Handler: func(_ any, _ context.Context, dec func(any) error, _ grpc.UnaryServerInterceptor) (any, error) {
				if err := dec(&pb.Bus_Fare{}); err != nil {
					return nil, err
				}
				return reply, nil
			},
		}},
		Streams: []grpc.StreamDesc{{
			StreamName: "Watch",
			Handler: func(_ any, stream grpc.ServerStream) error {
				if err := stream.RecvMsg(&pb.Bus_Fare{}); err != nil {
					return err
				}
				for range _compressionStreamFrames {
					if err := stream.SendMsg(reply); err != nil {
						return err
					}
				}
				return nil
			},
			ServerStreams: true,
		}},
	}

	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	srv.RegisterService(desc, struct{}{})
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	seen := &payloadSizes{}
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return lis.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithStatsHandler(seen),
	)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn, seen
}

// payloadSizes totals the sizes of the response payloads the test receives.
// Written from the client's single-goroutine RPC path, read after it finishes.
type payloadSizes struct {
	frames       int
	uncompressed int
	compressed   int
}

func (p *payloadSizes) HandleRPC(_ context.Context, s stats.RPCStats) {
	if in, ok := s.(*stats.InPayload); ok {
		p.frames++
		p.uncompressed += in.Length
		p.compressed += in.CompressedLength
	}
}

func (p *payloadSizes) TagRPC(ctx context.Context, _ *stats.RPCTagInfo) context.Context { return ctx }
func (p *payloadSizes) TagConn(ctx context.Context, _ *stats.ConnTagInfo) context.Context {
	return ctx
}
func (p *payloadSizes) HandleConn(context.Context, stats.ConnStats) {}
