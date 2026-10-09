package main

import (
	"net"
	"net/http"
	"net/url"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/riderfwd"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc"
)

// riderLink is api's connection to rider-api: gRPC for the forwarded RPCs and
// an HTTP reverse proxy for the Live Activity cancel.
type riderLink struct {
	conn        *grpc.ClientConn
	trackCancel gin.HandlerFunc
}

// dialRider connects to RIDER_API_ADDR (gRPC) and RIDER_HTTP_URL (HTTP),
// using the client certificate in RIDER_TLS_DIR when set. Both default to the
// in-cluster Service names.
func dialRider() (riderLink, error) {
	addr := envOr("RIDER_API_ADDR", "rider-api:50052")
	httpURL := envOr("RIDER_HTTP_URL", "http://rider-api:8090")
	tlsDir := os.Getenv("RIDER_TLS_DIR")
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return riderLink{}, _oops.With("addr", addr).Wrapf(err, "parse RIDER_API_ADDR")
	}
	creds, err := shared.GRPCClientCreds(tlsDir, host)
	if err != nil {
		return riderLink{}, err
	}
	conn, err := riderfwd.Dial(addr, grpc.WithTransportCredentials(creds))
	if err != nil {
		return riderLink{}, _oops.Wrapf(err, "dial rider-api")
	}
	target, err := url.Parse(httpURL)
	if err != nil {
		_ = conn.Close()
		return riderLink{}, _oops.With("url", httpURL).Wrapf(err, "parse RIDER_HTTP_URL")
	}
	transport := http.DefaultTransport
	if tlsDir != "" {
		cfg, err := shared.MTLSConfig(tlsDir, false, target.Hostname())
		if err != nil {
			_ = conn.Close()
			return riderLink{}, err
		}
		t := http.DefaultTransport.(*http.Transport).Clone()
		t.TLSClientConfig = cfg
		transport = t
	}
	return riderLink{conn: conn, trackCancel: riderfwd.TrackCancelProxy(target, transport)}, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
