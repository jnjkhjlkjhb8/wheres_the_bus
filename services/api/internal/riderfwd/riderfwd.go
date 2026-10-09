// Package riderfwd forwards the rider RPCs api receives on the public
// endpoint to rider-api over mutual TLS (ADR-0026). api has already applied
// App Check, rate limits and deadlines; rider-api re-checks the install
// credential, which is the only caller metadata passed through.
package riderfwd

import (
	"context"
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/gin-gonic/gin"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// _forwardedMetadata is the allowlist of incoming metadata keys rider-api
// receives. Anything else (App Check tokens, proxy headers) stays at api.
var _forwardedMetadata = []string{installid.MetadataKey, installid.SecretMetadataKey}

// Outgoing derives the context for a forwarded call: the caller's deadline and
// cancellation, plus the allowlisted metadata. Calls are never retried here;
// every rider RPC writes, and a retry after a lost reply could apply it twice.
func Outgoing(ctx context.Context) context.Context {
	in, _ := metadata.FromIncomingContext(ctx)
	out := metadata.MD{}
	for _, key := range _forwardedMetadata {
		if values := in.Get(key); len(values) > 0 {
			out.Set(key, values...)
		}
	}
	return metadata.NewOutgoingContext(ctx, out)
}

// Firebase forwards every Firebase_Service method.
type Firebase struct {
	pb.UnimplementedFirebase_ServiceServer
	Client pb.Firebase_ServiceClient
}

func (f Firebase) UpsertDevice(ctx context.Context, in *pb.UpsertDeviceRequest) (*pb.DeviceState, error) {
	return f.Client.UpsertDevice(Outgoing(ctx), in)
}

func (f Firebase) ReplaceRouteSubscriptions(ctx context.Context, in *pb.RouteSubscriptionsRequest) (*pb.Ack, error) {
	return f.Client.ReplaceRouteSubscriptions(Outgoing(ctx), in)
}

func (f Firebase) CreateArrivalReminder(ctx context.Context, in *pb.CreateArrivalReminderRequest) (*pb.ArrivalReminder, error) {
	return f.Client.CreateArrivalReminder(Outgoing(ctx), in)
}

func (f Firebase) CancelArrivalReminder(ctx context.Context, in *pb.CancelArrivalReminderRequest) (*pb.Ack, error) {
	return f.Client.CancelArrivalReminder(Outgoing(ctx), in)
}

func (f Firebase) ListDeviceState(ctx context.Context, in *pb.DeviceRequest) (*pb.DeviceState, error) {
	return f.Client.ListDeviceState(Outgoing(ctx), in)
}

// Feedback forwards Feedback_Service.
type Feedback struct {
	pb.UnimplementedFeedback_ServiceServer
	Client pb.Feedback_ServiceClient
}

func (f Feedback) PostFeedback(ctx context.Context, in *pb.PostFeedbackRequest) (*pb.ReportReceipt, error) {
	return f.Client.PostFeedback(Outgoing(ctx), in)
}

// Dial opens the connection to rider-api with creds; grpc dials lazily, so a
// rider-api that is still starting fails the first calls, not api's boot.
func Dial(target string, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	return grpc.NewClient(target, opts...)
}

// TrackCancelPath is the Live Activity "stop tracking" endpoint. It carries
// no install credential (the activity has none), so rider-api authorizes it by
// the unguessable track id and api passes the request through unchanged.
const TrackCancelPath = "/api/track/cancel"

// HTTPTrackCancelRateLimit bounds the endpoint per client and minute. One press
// ends one ride; the limit is sized for a retry loop, not for traffic.
const HTTPTrackCancelRateLimit = 20

// TrackCancelProxy reverse-proxies the cancel endpoint to rider-api's HTTP
// listener at target, through transport (mutual TLS in the cluster).
func TrackCancelProxy(target *url.URL, transport http.RoundTripper) gin.HandlerFunc {
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = transport
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		zap.S().Warnw("failed", "component", "riderfwd", "action", "track_cancel", "event", "proxy_failed", "err", err)
		w.WriteHeader(http.StatusBadGateway)
	}
	return func(c *gin.Context) {
		proxy.ServeHTTP(c.Writer, c.Request)
	}
}
