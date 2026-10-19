package main

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/metrotrack"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/notify"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

func TestRiderServerConstructionAndNativeShutdown(t *testing.T) {
	grpcServer, err := newRiderGRPCServer(nil, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(grpcServer.GetServiceInfo()) != 3 {
		t.Fatalf("services=%v", grpcServer.GetServiceInfo())
	}
	httpServer, err := newRiderHTTPServer(nil, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if httpServer.ReadHeaderTimeout != 5*time.Second || httpServer.Addr != _riderHTTPAddr || httpServer.TLSConfig != nil {
		t.Fatalf("HTTP configuration=%v", httpServer)
	}
	request := httptest.NewRequest(http.MethodPost, metrotrack.TrackCancelPath, strings.NewReader(`{"track_id":"invalid"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	httpServer.Handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("cancel validation=%d", response.Code)
	}
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	httpServer.Addr = "127.0.0.1:0"
	shutdown := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- serveRiderServers(grpcServer, httpServer, lis, "", func() { <-shutdown }) }()
	conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		close(shutdown)
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err = pb.NewFirebase_ServiceClient(conn).ListDeviceState(ctx, &pb.DeviceRequest{})
	if status.Code(err) != codes.InvalidArgument {
		close(shutdown)
		t.Fatalf("native RPC validation=%v", err)
	}
	close(shutdown)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("servers failed to drain")
	}
	for _, constructor := range []func() error{func() error { _, err := newRiderGRPCServer(nil, nil, t.TempDir()); return err }, func() error { _, err := newRiderHTTPServer(nil, nil, t.TempDir()); return err }} {
		if err := constructor(); err == nil {
			t.Fatal("missing TLS files accepted")
		}
	}
}

func TestRiderServerStartupFailureAndClosedHTTPListener(t *testing.T) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_ = lis.Close()
	shutdown := make(chan struct{})
	defer close(shutdown)
	if err := serveRiderServers(grpc.NewServer(), &http.Server{Addr: "127.0.0.1:0"}, lis, "", func() { <-shutdown }); err == nil {
		t.Fatal("closed gRPC listener served successfully")
	}
	closed := &http.Server{}
	_ = closed.Close()
	if err := listenRiderHTTP(closed); err != nil {
		t.Fatalf("closed HTTP=%v", err)
	}
	if err := listenRiderHTTP(&http.Server{Addr: "invalid address", TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}}); err == nil {
		t.Fatal("invalid TLS listener succeeded")
	}
}

func TestRiderHealthMarkerAndCommandValidation(t *testing.T) {
	for _, args := range [][]string{nil, {"api", "worker"}, {"unknown"}} {
		if err := run(args); err == nil || err.Error() != "usage: rider <api|worker>" {
			t.Fatalf("args=%v err=%v", args, err)
		}
	}
	(*healthFile)(nil).touch()
	path := filepath.Join(t.TempDir(), "healthy")
	h := newHealthFile(path)
	h.touch()
	first, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	h.touch()
	last, err := os.Stat(path)
	if err != nil || !last.ModTime().After(first.ModTime().Add(-time.Second)) {
		t.Fatalf("health marker=%v %v", last, err)
	}
	newHealthFile(filepath.Join(path, "missing", "healthy")).touch()
	t.Setenv("HEALTH_FILE", path)
	if defaultHealthFilePath() != path {
		t.Fatal("health path ignored")
	}
	t.Setenv("HEALTH_FILE", "")
	if defaultHealthFilePath() != "/tmp/healthy" {
		t.Fatal("default health path changed")
	}
}

func TestArrivalConsumerRunsAndAcknowledgesMalformedEntries(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR required")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 14})
	t.Cleanup(func() { rc.Del(context.Background(), riderevent.StreamKey); _ = rc.Close() })
	rc.Del(context.Background(), riderevent.StreamKey)
	consumer := newArrivalConsumer(rc, &recordingHandler{})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { consumer.run(ctx); close(done) }()
	waitCtx, stop := context.WithTimeout(context.Background(), 2*time.Second)
	defer stop()
	for {
		if _, err := rc.XInfoGroups(waitCtx, riderevent.StreamKey).Result(); err == nil {
			break
		}
		select {
		case <-waitCtx.Done():
			cancel()
			t.Fatal("arrival group not created")
		case <-time.After(time.Millisecond * 5):
		}
	}
	if err := rc.XAdd(ctx, &redis.XAddArgs{Stream: riderevent.StreamKey, Values: map[string]any{"bad": "payload"}}).Err(); err != nil {
		cancel()
		t.Fatal(err)
	}
	for {
		groups, err := rc.XInfoGroups(waitCtx, riderevent.StreamKey).Result()
		if err == nil && len(groups) == 1 && groups[0].LastDeliveredID != "0-0" && rc.XPending(waitCtx, riderevent.StreamKey, riderevent.Group).Val().Count == 0 {
			break
		}
		select {
		case <-waitCtx.Done():
			cancel()
			t.Fatal("malformed arrival not acknowledged")
		case <-time.After(time.Millisecond * 5):
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(7 * time.Second):
		t.Fatal("consumer failed to exit")
	}
	closed := redis.NewClient(&redis.Options{Addr: addr})
	_ = closed.Close()
	consumer.rc = closed
	canceled, cancelNow := context.WithCancel(context.Background())
	cancelNow()
	consumer.run(canceled)
	deadline, stopDeadline := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer stopDeadline()
	consumer.consumeBatch(deadline)
	sleepCtx(context.Background(), time.Millisecond)
	sleepCtx(canceled, time.Hour)
	if !errors.Is(deadline.Err(), context.DeadlineExceeded) {
		t.Fatal("consumer did not honor deadline")
	}
}

func TestRiderCommandDispatchAndExitStatus(t *testing.T) {
	expected := errors.New("command failed")
	var dispatched []string
	for _, command := range []string{"api", "worker"} {
		err := dispatchRiderCommand(command, func() error { dispatched = append(dispatched, "api"); return expected }, func() error { dispatched = append(dispatched, "worker"); return expected })
		if !errors.Is(err, expected) {
			t.Fatalf("%s error=%v", command, err)
		}
	}
	if len(dispatched) != 2 || dispatched[0] != "api" || dispatched[1] != "worker" {
		t.Fatalf("dispatch=%v", dispatched)
	}
	var output strings.Builder
	if commandExitCode(nil, &output) != 0 || output.Len() != 0 {
		t.Fatal("success reported failure")
	}
	if commandExitCode(expected, &output) != 1 || output.String() != "rider exited with error: command failed\n" {
		t.Fatalf("failure output=%q", output.String())
	}
}

func TestRiderPushStartupRejectsInvalidProviders(t *testing.T) {
	t.Setenv("APP_ENV", "test")
	t.Setenv("FIREBASE_ENABLED", "true")
	t.Setenv("FIREBASE_PROJECT_ID", "")
	if _, _, err := riderPushServices(nil); err == nil || !strings.Contains(err.Error(), "init Firebase sender") {
		t.Fatalf("Firebase startup error=%v", err)
	}
	t.Setenv("FIREBASE_ENABLED", "false")
	for key, value := range map[string]string{"APNS_KEY_ID": "key", "APNS_TEAM_ID": "team", "APNS_TOPIC": "test.topic", "APNS_P8": "invalid pem"} {
		t.Setenv(key, value)
	}
	if _, _, err := riderPushServices(nil); err == nil || !strings.Contains(err.Error(), "init APNs sender") {
		t.Fatalf("APNs startup error=%v", err)
	}
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	closeRiderRedis(rc)
}

func TestRiderScheduledJobsHandleDisabledPushAndEmptyStore(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" {
		t.Skip("requires disposable PostgreSQL URL")
	}
	db, _ := riderWorkerTestPool(t)
	if _, err := db.Exec(context.Background(), `ALTER TABLE firebase_arrival_reminder ADD COLUMN updated_at timestamptz;
 CREATE TABLE route_alert_outbox(id bigint,route_type text,route_key text,body text,processed_at timestamptz,claimed_until timestamptz,attempts int,created_at timestamptz)`); err != nil {
		t.Fatal(err)
	}
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	t.Setenv("TRTC_USERNAME", "")
	t.Setenv("TRTC_PASSWORD", "")
	oldHealth := _health
	_health = newHealthFile(filepath.Join(t.TempDir(), "healthy"))
	t.Cleanup(func() { _health = oldHealth })
	r := cron.New(cron.WithSeconds())
	dispatcher := notify.NewDispatcher(notify.NewStore(db), nil)
	registerRiderJobs(r, rc, db, dispatcher, notify.NewTrackPusher(nil, nil))
	entries := r.Entries()
	if len(entries) != 4 {
		t.Fatalf("rider scheduled jobs=%d", len(entries))
	}
	for _, entry := range entries {
		entry.Job.Run()
	}
	if _, err := os.Stat(_health.path); err != nil {
		t.Fatal(err)
	}
}
