package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/alert"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/feedback"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/firebase"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/installid"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/maas"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/metro"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/nearby"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/rail"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/transit"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"

	_ "google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/status"
)

// logPoolStats logs the DB pool's stats once a minute until stop is closed.
func logPoolStats(pool *pgxpool.Pool, stop <-chan struct{}) {
	t := time.NewTicker(1 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			s := pool.Stat()
			zap.S().Infow("log",
				"component", "db",
				"action", "pool_stat",
				"total", s.TotalConns(),
				"acquired", s.AcquiredConns(),
				"idle", s.IdleConns(),
				"empty_acquires", s.EmptyAcquireCount(),
				"max", s.MaxConns(),
			)
		case <-stop:
			return
		}
	}
}

func installationRateLimitInterceptor(rl *ratelimit.Limiter, limit int, window time.Duration) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if !strings.HasPrefix(info.FullMethod, "/Firebase_Service/") {
			return handler(ctx, req)
		}
		installID, ok := installid.CallerID(ctx)
		if ok && !rl.Allow(info.FullMethod, "install:"+installID, limit, window) {
			return nil, status.Error(codes.ResourceExhausted, "installation rate limit exceeded")
		}
		return handler(ctx, req)
	}
}

func productionUnaryInterceptors(
	appCheckVerifier firebase.AppCheckVerifier,
	enforceAppCheck bool,
	maasRL *ratelimit.Limiter,
) []grpc.UnaryServerInterceptor {
	return []grpc.UnaryServerInterceptor{
		obs.UnaryInterceptor(),
		ratelimit.UnaryInterceptor(ratelimit.New(), 30, time.Second),
		maas.MaasResourceInterceptor(maasRL, maas.DefaultMaasResourceConfig),
		firebase.AppCheckUnaryInterceptor(appCheckVerifier, enforceAppCheck),
		installationRateLimitInterceptor(ratelimit.New(), 30, time.Second),
	}
}

type coordinatedGRPCServer interface {
	Serve(net.Listener) error
	GracefulStop()
	Stop()
}

type coordinatedHTTPServer interface {
	Serve(net.Listener) error
	Shutdown(context.Context) error
	Close() error
}

type serverCoordinator struct {
	grpcServer       coordinatedGRPCServer
	httpServer       coordinatedHTTPServer
	shutdownTimeout  time.Duration
	waitHTTPHandlers func()
	capture          func(error)
	shutdown         <-chan os.Signal
}

type serverResult struct {
	name string
	err  error
}

func (c serverCoordinator) serve(grpcListener, httpListener net.Listener) error {
	results := make(chan serverResult, 2)
	go func() {
		results <- serverResult{name: "gRPC", err: c.grpcServer.Serve(grpcListener)}
	}()
	go func() {
		results <- serverResult{name: "HTTP", err: c.httpServer.Serve(httpListener)}
	}()

	var serveErr error
	select {
	case first := <-results:
		serveErr = unexpectedServeError(first)
		c.stopServers()
		<-results // Both Serve goroutines must finish before backend cleanup.
	case <-c.shutdown:
		zap.S().Infow("signal received", "component", "router", "action", "shutdown", "event", "signal_received")
		c.stopServers()
		<-results // Both Serve goroutines must finish before backend cleanup.
		<-results
	}
	if c.capture != nil {
		c.capture(serveErr)
	}
	return serveErr
}

func unexpectedServeError(result serverResult) error {
	if result.err == nil || (result.name == "HTTP" && errors.Is(result.err, http.ErrServerClosed)) {
		return _oops.With("result_name", result.name).Errorf("server stopped unexpectedly")
	}
	return _oops.With("result_name", result.name).Wrapf(result.err, "server failed")
}

func (c serverCoordinator) stopServers() {
	timeout := c.shutdownTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	var stopped sync.WaitGroup
	stopped.Add(2)
	go func() {
		defer stopped.Done()
		gracefulDone := make(chan struct{})
		go func() {
			c.grpcServer.GracefulStop()
			close(gracefulDone)
		}()
		select {
		case <-gracefulDone:
		case <-time.After(timeout):
			c.grpcServer.Stop()
			<-gracefulDone
		}
	}()
	go func() {
		defer stopped.Done()
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		if err := c.httpServer.Shutdown(ctx); err != nil {
			_ = c.httpServer.Close()
		}
		if c.waitHTTPHandlers != nil {
			c.waitHTTPHandlers()
		}
	}()
	stopped.Wait()
}

type routerRuntime struct {
	cleanups []func()
}

func (r *routerRuntime) addCleanup(cleanup func()) {
	r.cleanups = append(r.cleanups, cleanup)
}

func (r *routerRuntime) run(start func() error) error {
	defer func() {
		for index := len(r.cleanups) - 1; index >= 0; index-- {
			r.cleanups[index]()
		}
	}()
	return start()
}

func run() error {
	runtime := &routerRuntime{}
	return runtime.run(func() error {
		runtime.addCleanup(obs.Init("router"))
		shutdownSignal := make(chan os.Signal, 1)
		signal.Notify(shutdownSignal, syscall.SIGINT, syscall.SIGTERM)
		runtime.addCleanup(func() { signal.Stop(shutdownSignal) })
		httpConfig, err := httpServerConfigFromEnv()
		if err != nil {
			return _oops.Wrapf(err, "HTTP configuration failed before startup")
		}
		rc := shared.ConnectRedis()
		runtime.addCleanup(func() {
			if err := rc.Close(); err != nil {
				zap.S().Errorw("failed", "component", "redis", "action", "close", "event", "failed", "err", err)
			}
		})
		live := livestream.NewLiveHubWithQueueSize(
			livestream.NewRedisLiveSource(rc),
			int(shared.EnvInt32("ROUTER_MAX_LIVE_STREAMS", 2000)),
			int(shared.EnvInt32("ROUTER_LIVE_SUBSCRIBER_QUEUE", livestream.DefaultSubscriberQueueSize)),
		)
		db := shared.ConnectDB("ROUTER_DB_MAX_CONNS", 20)
		runtime.addCleanup(db.Close)
		poolStatsStop := make(chan struct{})
		poolStatsDone := make(chan struct{})
		go func() {
			defer close(poolStatsDone)
			logPoolStats(db, poolStatsStop)
		}()
		runtime.addCleanup(func() {
			close(poolStatsStop)
			<-poolStatsDone
		})
		tdx := shared.NewTDXClient(shared.TDXConfig{
			Store:  shared.RedisTDXStore{RC: rc},
			IMSKey: shared.TDXLegacyIMSKey,
		})
		httpConfig.booking = rail.NewBookingProxy(tdx)
		// Same client the live streams use: the GBFS station_status feed reads the
		// bike availability keys bikeEta writes, so it needs no cache of its own.
		httpConfig.redis = rc
		maasCache := maas.NewRedisMaasCache(rc.Options())
		runtime.addCleanup(func() {
			if err := maasCache.Close(); err != nil {
				zap.S().Errorw("failed", "component", "maas", "action", "cache_close", "event", "failed", "err", err)
			}
		})
		lis, err := net.Listen("tcp", "0.0.0.0:50051")
		if err != nil {
			return _oops.Wrapf(err, "listen for gRPC")
		}
		runtime.addCleanup(func() { _ = lis.Close() })
		motisBaseURL := maas.MotisBaseURLFromEnv()
		var plannerMonitor *maas.PlannerHealthMonitor
		if httpConfig.MotisEnabled {
			plannerMonitor = maas.NewPlannerHealthMonitor(maas.NewMotisHealthClient(motisBaseURL))
			healthCtx, stopHealth := context.WithCancel(context.Background())
			runtime.addCleanup(stopHealth)
			plannerMonitor.Start(healthCtx)
		}
		httpConfig.plannerHealth = plannerMonitor
		httpRuntime, err := prepareHTTPServer(db, live, httpConfig, loadOrGenerateKey, net.Listen)
		if err != nil {
			return err
		}
		runtime.addCleanup(func() { _ = httpRuntime.listener.Close() })
		rl := ratelimit.NewWithTrustedProxies(httpConfig.TrustedProxies)
		tlsCredentials, err := firebase.GRPCTLSCredentialsFromEnv()
		if err != nil {
			return _oops.Wrapf(err, "gRPC TLS initialization failed")
		}
		appCheckVerifier, enforceAppCheck, err := firebase.FirebaseAppCheckFromEnv(context.Background())
		if err != nil {
			return _oops.Wrapf(err, "initialize Firebase Admin")
		}
		// One limiter across both chains so the TDX quota is spent per caller,
		// not per method (see _maasQuotaScope).
		maasRL := ratelimit.NewWithTrustedProxies(httpConfig.TrustedProxies)
		serverOptions := []grpc.ServerOption{
			// Stop is the bounded GracefulStop fallback. Waiting for handlers here
			// keeps backend ownership valid until canceled RPC handlers return.
			grpc.WaitForHandlers(true),
			grpc.ChainUnaryInterceptor(productionUnaryInterceptors(appCheckVerifier, enforceAppCheck, maasRL)...),
			grpc.ChainStreamInterceptor(
				obs.StreamInterceptor(),
				ratelimit.StreamInterceptor(rl, 30, time.Second),
				maas.MaasResourceStreamInterceptor(maasRL, maas.DefaultMaasResourceConfig),
				firebase.AppCheckStreamInterceptor(appCheckVerifier, enforceAppCheck),
			),
		}
		if tlsCredentials != nil {
			serverOptions = append(serverOptions, grpc.Creds(tlsCredentials))
		}
		grpcServer := grpc.NewServer(serverOptions...)
		pb.RegisterBus_Route_ServiceServer(grpcServer, transit.NewBusRouteServer(db, rc, cache.NewTTLCache(), live))
		pb.RegisterBus_Station_ServiceServer(grpcServer, transit.NewBusStationServer(db, rc, live))
		pb.RegisterBike_ServiceServer(grpcServer, transit.NewBikeServer(db, rc, cache.NewTTLCache(), live))
		pb.RegisterMrt_ServiceServer(grpcServer, metro.NewMrtServer(
			db, rc, live,
			firebase.NewFirebaseStore(db),
			shared.NewTRTCTrainInfoClient(os.Getenv("TRTC_USERNAME"), os.Getenv("TRTC_PASSWORD")),
			time.Now,
		))
		pb.RegisterThsrTimetableServiceServer(grpcServer, rail.NewThsrServer(db, rc, live))
		pb.RegisterTRATimetableServiceServer(grpcServer, rail.NewTraTimetableServer(db, rc, live))
		pb.RegisterTRA_DetainServiceServer(grpcServer, rail.NewTraDetainServer(db, rc, live))
		pb.RegisterThsr_DetainServiceServer(grpcServer, rail.NewThsrDetainServer(db, rc, live))
		nearbyRouter := nearby.NewMotisWalkingRouter(resty.New().SetTimeout(5*time.Second), motisBaseURL)
		pb.RegisterNear_Station_ServiceServer(grpcServer, transit.NewNearServer(nearby.NewNearbyDiscovery(nearby.NewPostgresNearbyStore(db), nearbyRouter)))
		pb.RegisterAlert_ServiceServer(grpcServer, alert.NewAlertServer(live))
		maasWorkConfig := maas.DefaultMaasSharedWorkConfig
		if httpConfig.MotisEnabled {
			maasWorkConfig.Motis = maas.NewMotisClient(motisBaseURL)
			// The same monitor /api/planner reports, so the backend the app is
			// told about is the backend that answers its next plan request.
			maasWorkConfig.Health = plannerMonitor
		}
		zap.S().Infow("planner selected",
			"component", "maas",
			"action", "startup",
			"backend", maas.BackendName(maasWorkConfig.Motis != nil),
			"motis_base_url", motisBaseURL,
		)
		maasServer := maas.NewMaasServerWithCache(maasCache, db, tdx, maasWorkConfig)
		// Registered after rc/db/maasCache's cleanups above, so in cleanup's
		// LIFO order maas.MaasServer.Close runs first: every shared singleflight
		// flight is canceled and joined before those backends close under it.
		runtime.addCleanup(maasServer.Close)
		pb.RegisterMaasServiceServer(grpcServer, maasServer)
		pb.RegisterFirebase_ServiceServer(grpcServer,
			firebase.NewFirebaseServer(firebase.NewFirebaseStore(db), time.Now, live))
		pb.RegisterFeedback_ServiceServer(grpcServer, feedback.NewFeedbackServer(
			feedback.NewFeedbackStore(db),
			firebase.NewFirebaseStore(db),
			feedback.NewFeedbackNotifier(),
		))
		zap.S().Infow("gRPC server is running", "port", 50051)
		zap.S().Infow("server running on 0.0.0.0:8080", "component", "http")
		coordinator := serverCoordinator{
			grpcServer:       grpcServer,
			httpServer:       httpRuntime.server,
			waitHTTPHandlers: httpRuntime.handlers.stopAndWait,
			shutdownTimeout:  5 * time.Second,
			shutdown:         shutdownSignal,
			capture: func(err error) {
				obs.Capture("router-serve", err)
			},
		}
		return coordinator.serve(lis, httpRuntime.listener)
	})
}

func reportProcessFailure(w io.Writer, err error) {
	_, _ = fmt.Fprintf(w, "router exited with error: %v\n", err)
}

func main() {
	if err := run(); err != nil {
		reportProcessFailure(os.Stderr, err)
		os.Exit(1)
	}
}
