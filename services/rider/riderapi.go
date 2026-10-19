package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/feedback"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/firebase"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/metrotrack"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/grpc"
)

const (
	_riderGRPCAddr = ":50052"
	_riderHTTPAddr = ":8090"
	// _riderStopTimeout bounds GracefulStop; Kubernetes' preStop has already
	// taken the pod out of the Service, so only in-flight calls remain.
	_riderStopTimeout = 10 * time.Second
)

// runAPI serves the rider RPCs api forwards, over mutual TLS when
// RIDER_TLS_DIR is set. App Check and rate limits are enforced at api, the
// public boundary; this server still checks every install credential itself.
func runAPI() error { return runRiderAPI(waitForShutdown, _riderGRPCAddr, _riderHTTPAddr) }

func runRiderAPI(waitShutdown func(), grpcAddr, httpAddr string) error {
	rc := shared.ConnectRedis()
	defer func() { _ = rc.Close() }()
	db := shared.ConnectDB("RIDER_DB_MAX_CONNS", 5)
	defer db.Close()
	tlsDir := os.Getenv("RIDER_TLS_DIR")
	grpcServer, err := newRiderGRPCServer(db, rc, tlsDir)
	if err != nil {
		return err
	}
	return startRiderHTTPAndGRPC(db, rc, tlsDir, grpcServer, grpcAddr, httpAddr, waitShutdown)
}

func startRiderHTTPAndGRPC(db *pgxpool.Pool, rc *redis.Client, tlsDir string, grpcServer *grpc.Server, grpcAddr, httpAddr string, waitShutdown func()) error {
	httpServer, err := newRiderHTTPServer(db, rc, tlsDir)
	if err != nil {
		return err
	}
	httpServer.Addr = httpAddr
	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		return _oops.Wrapf(err, "listen for rider gRPC")
	}
	return serveRiderServers(grpcServer, httpServer, lis, tlsDir, waitShutdown)
}

func newRiderGRPCServer(db *pgxpool.Pool, rc *redis.Client, tlsDir string) (*grpc.Server, error) {
	creds, err := shared.GRPCServerCreds(tlsDir)
	if err != nil {
		return nil, err
	}
	opts := []grpc.ServerOption{
		grpc.WaitForHandlers(true),
		grpc.ChainUnaryInterceptor(obs.UnaryInterceptor()),
	}
	if creds != nil {
		opts = append(opts, grpc.Creds(creds))
	}
	grpcServer := grpc.NewServer(opts...)
	store := firebase.NewFirebaseStore(db)
	pb.RegisterFirebase_ServiceServer(grpcServer, firebase.NewFirebaseServer(store, time.Now, firebase.RedisDemand{RC: rc}))
	pb.RegisterFeedback_ServiceServer(grpcServer, feedback.NewFeedbackServer(
		feedback.NewFeedbackStore(db), store, feedback.NewFeedbackNotifier()))
	pb.RegisterMrt_ServiceServer(grpcServer, metrotrack.NewMrtServer(
		db, rc, store,
		shared.NewTRTCTrainInfoClient(os.Getenv("TRTC_USERNAME"), os.Getenv("TRTC_PASSWORD")),
		time.Now,
	))

	return grpcServer, nil
}

func newRiderHTTPServer(db *pgxpool.Pool, rc *redis.Client, tlsDir string) (*http.Server, error) {
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())
	router.POST(metrotrack.TrackCancelPath, metrotrack.HandleTrackCancel(metrotrack.TrackCancelStoreFor(db), rc))
	httpServer := &http.Server{Addr: _riderHTTPAddr, Handler: router, ReadHeaderTimeout: 5 * time.Second}
	if tlsDir != "" {
		cfg, err := shared.MTLSConfig(tlsDir, true, "")
		if err != nil {
			return nil, err
		}
		httpServer.TLSConfig = cfg
	}

	return httpServer, nil
}

func serveRiderServers(grpcServer *grpc.Server, httpServer *http.Server, lis net.Listener, tlsDir string, waitShutdown func()) error {
	errs := make(chan error, 2)
	go func() { errs <- grpcServer.Serve(lis) }()
	go func() {
		err := listenRiderHTTP(httpServer)
		errs <- err
	}()
	zap.S().Infow("serving", "component", "rider_api", "grpc", _riderGRPCAddr, "http", _riderHTTPAddr, "mtls", tlsDir != "")

	shutdown := make(chan struct{})
	go func() {
		waitShutdown()
		close(shutdown)
	}()
	select {
	case err := <-errs:
		grpcServer.Stop()
		_ = httpServer.Close()
		return err
	case <-shutdown:
	}
	return stopRiderServers(grpcServer, httpServer)
}

func listenRiderHTTP(httpServer *http.Server) error {
	var err error
	if httpServer.TLSConfig != nil {
		err = httpServer.ListenAndServeTLS("", "")
	} else {
		err = httpServer.ListenAndServe()
	}
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	return err
}

func stopRiderServers(grpcServer *grpc.Server, httpServer *http.Server) error {
	stopped := make(chan struct{})
	go func() {
		grpcServer.GracefulStop()
		close(stopped)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), _riderStopTimeout)
	defer cancel()
	_ = httpServer.Shutdown(ctx)
	select {
	case <-stopped:
	case <-ctx.Done():
		grpcServer.Stop()
	}
	return nil
}
