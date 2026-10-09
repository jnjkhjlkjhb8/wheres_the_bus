package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/feedback"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/firebase"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/metrotrack"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
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
func runAPI() error {
	rc := shared.ConnectRedis()
	defer func() { _ = rc.Close() }()
	db := shared.ConnectDB("RIDER_DB_MAX_CONNS", 5)
	defer db.Close()
	tlsDir := os.Getenv("RIDER_TLS_DIR")

	creds, err := shared.GRPCServerCreds(tlsDir)
	if err != nil {
		return err
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

	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())
	router.POST(metrotrack.TrackCancelPath, metrotrack.HandleTrackCancel(metrotrack.TrackCancelStoreFor(db), rc))
	httpServer := &http.Server{Addr: _riderHTTPAddr, Handler: router, ReadHeaderTimeout: 5 * time.Second}
	if tlsDir != "" {
		cfg, err := shared.MTLSConfig(tlsDir, true, "")
		if err != nil {
			return err
		}
		httpServer.TLSConfig = cfg
	}

	lis, err := net.Listen("tcp", _riderGRPCAddr)
	if err != nil {
		return _oops.Wrapf(err, "listen for rider gRPC")
	}
	errs := make(chan error, 2)
	go func() { errs <- grpcServer.Serve(lis) }()
	go func() {
		var err error
		if httpServer.TLSConfig != nil {
			err = httpServer.ListenAndServeTLS("", "")
		} else {
			err = httpServer.ListenAndServe()
		}
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		errs <- err
	}()
	zap.S().Infow("serving", "component", "rider_api", "grpc", _riderGRPCAddr, "http", _riderHTTPAddr, "mtls", tlsDir != "")

	shutdown := make(chan struct{})
	go func() {
		waitForShutdown()
		close(shutdown)
	}()
	select {
	case err := <-errs:
		grpcServer.Stop()
		_ = httpServer.Close()
		return err
	case <-shutdown:
	}
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
