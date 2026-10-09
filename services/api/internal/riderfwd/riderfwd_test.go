package riderfwd

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

// fakeRider stands in for rider-api and records what each call carried.
type fakeRider struct {
	pb.UnimplementedFirebase_ServiceServer
	md          metadata.MD
	hasDeadline bool
	err         error
}

func (f *fakeRider) UpsertDevice(ctx context.Context, _ *pb.UpsertDeviceRequest) (*pb.DeviceState, error) {
	f.md, _ = metadata.FromIncomingContext(ctx)
	_, f.hasDeadline = ctx.Deadline()
	return &pb.DeviceState{}, f.err
}

// serve starts a gRPC server on an in-memory listener and returns a client
// connection to it.
func serve(t *testing.T, register func(*grpc.Server)) *grpc.ClientConn {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	register(srv)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return lis.Dial() }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

// gateway runs Firebase forwarding in front of rider, the way api does, and
// returns a client for the public side.
func gateway(t *testing.T, rider *fakeRider) pb.Firebase_ServiceClient {
	t.Helper()
	riderConn := serve(t, func(s *grpc.Server) { pb.RegisterFirebase_ServiceServer(s, rider) })
	apiConn := serve(t, func(s *grpc.Server) {
		pb.RegisterFirebase_ServiceServer(s, Firebase{Client: pb.NewFirebase_ServiceClient(riderConn)})
	})
	return pb.NewFirebase_ServiceClient(apiConn)
}

func TestForwardPassesOnlyInstallCredentialAndDeadline(t *testing.T) {
	rider := &fakeRider{}
	client := gateway(t, rider)
	ctx := metadata.AppendToOutgoingContext(context.Background(),
		installid.MetadataKey, "install-1",
		installid.SecretMetadataKey, "secret-1",
		"x-firebase-appcheck", "token",
		"x-forwarded-for", "1.2.3.4",
	)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := client.UpsertDevice(ctx, &pb.UpsertDeviceRequest{}); err != nil {
		t.Fatal(err)
	}
	if got := rider.md.Get(installid.MetadataKey); len(got) != 1 || got[0] != "install-1" {
		t.Fatalf("install id = %v", got)
	}
	if got := rider.md.Get(installid.SecretMetadataKey); len(got) != 1 || got[0] != "secret-1" {
		t.Fatalf("install secret = %v", got)
	}
	for _, key := range []string{"x-firebase-appcheck", "x-forwarded-for"} {
		if got := rider.md.Get(key); len(got) != 0 {
			t.Errorf("%s reached rider-api: %v", key, got)
		}
	}
	if !rider.hasDeadline {
		t.Error("caller deadline was not forwarded")
	}
}

func TestForwardReturnsRiderStatusUnchanged(t *testing.T) {
	client := gateway(t, &fakeRider{err: status.Error(codes.PermissionDenied, "wrong secret")})
	_, err := client.UpsertDevice(context.Background(), &pb.UpsertDeviceRequest{})
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("code = %v, want PermissionDenied from rider-api", status.Code(err))
	}
}

func TestTrackCancelProxyPassesThroughAndReportsBadGateway(t *testing.T) {
	var gotPath, gotBody string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		buf := make([]byte, 64)
		n, _ := r.Body.Read(buf)
		gotBody = string(buf[:n])
		w.WriteHeader(http.StatusNoContent)
	}))
	defer upstream.Close()
	target, _ := url.Parse(upstream.URL)

	// A real server, not a ResponseRecorder: ReverseProxy needs CloseNotify,
	// which the recorder does not implement.
	gin.SetMode(gin.TestMode)
	post := func(target *url.URL) int {
		t.Helper()
		r := gin.New()
		r.POST(TrackCancelPath, TrackCancelProxy(target, http.DefaultTransport))
		front := httptest.NewServer(r)
		t.Cleanup(front.Close)
		resp, err := http.Post(front.URL+TrackCancelPath, "application/json", strings.NewReader(`{"track_id":"x"}`))
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}
	if code := post(target); code != http.StatusNoContent || gotPath != TrackCancelPath || gotBody != `{"track_id":"x"}` {
		t.Fatalf("code=%d path=%q body=%q", code, gotPath, gotBody)
	}
	dead, _ := url.Parse("http://127.0.0.1:1")
	if code := post(dead); code != http.StatusBadGateway {
		t.Fatalf("unreachable rider-api = %d, want 502", code)
	}
}
