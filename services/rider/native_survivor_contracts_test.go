package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"firebase.google.com/go/v4/messaging"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/firebase"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/notify"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/pashagolub/pgxmock/v4"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/grpc"
)

func riderContractLogs(t *testing.T) *observer.ObservedLogs {
	t.Helper()
	core, logs := observer.New(zap.DebugLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(undo)
	return logs
}

func riderActionLogs(logs *observer.ObservedLogs, component, action string) []observer.LoggedEntry {
	return logs.Filter(func(entry observer.LoggedEntry) bool {
		fields := entry.ContextMap()
		return fields["component"] == component && fields["action"] == action
	}).All()
}

func riderLoggedCause(t *testing.T, entries []observer.LoggedEntry, cause error) {
	t.Helper()
	for _, entry := range entries {
		for _, field := range entry.Context {
			if err, ok := field.Interface.(error); field.Key == "err" && ok && errors.Is(err, cause) {
				return
			}
		}
	}
	t.Fatalf("original error %v missing from diagnostics: %+v", cause, entries)
}

func TestArrivalConsumerIdentityIsVisibleInRedis(t *testing.T) {
	rc := testRedis(t)
	name, err := os.Hostname()
	if err != nil || name == "" {
		t.Skip("host name unavailable")
	}
	c := newArrivalConsumer(rc, &recordingHandler{})
	ctx := context.Background()
	if err := c.ensureGroup(ctx); err != nil {
		t.Fatal(err)
	}
	if err := (riderevent.Publisher{RC: rc}).Arrivals(ctx, []riderevent.ArrivalEvent{{RouteKey: "identity"}}); err != nil {
		t.Fatal(err)
	}
	readNew(t, rc, c)
	consumers, err := rc.XInfoConsumers(ctx, riderevent.StreamKey, riderevent.Group).Result()
	if err != nil {
		t.Fatal(err)
	}
	if len(consumers) != 1 || consumers[0].Name != name || consumers[0].Pending != 1 {
		t.Fatalf("worker identity/pending=%+v, hostname=%q", consumers, name)
	}
}

func TestArrivalAtTwoMinuteBoundaryIsDispatchedAndAcknowledged(t *testing.T) {
	rc := testRedis(t)
	h := &recordingHandler{}
	c := newArrivalConsumer(rc, h)
	now := time.UnixMilli(1700000000000)
	c.now = func() time.Time { return now }
	ctx := context.Background()
	if err := c.ensureGroup(ctx); err != nil {
		t.Fatal(err)
	}
	event := riderevent.ArrivalEvent{RouteType: "bus", RouteKey: "boundary", StopKey: "stop", ETASeconds: 1}
	if err := (riderevent.Publisher{RC: rc, Now: func() time.Time { return now.Add(-2 * time.Minute) }}).Arrivals(ctx, []riderevent.ArrivalEvent{event}); err != nil {
		t.Fatal(err)
	}
	c.handle(ctx, readNew(t, rc, c))
	if !reflect.DeepEqual(h.batches, [][]riderevent.ArrivalEvent{{event}}) || pendingCount(t, rc) != 0 {
		t.Fatalf("boundary dispatch=%+v, pending=%d", h.batches, pendingCount(t, rc))
	}
}

type riderDeadlineHandler struct {
	before, after time.Time
	deadline      time.Time
	ctxErr        error
}

func (h *riderDeadlineHandler) Arrivals(ctx context.Context, _ []riderevent.ArrivalEvent) error {
	h.before = time.Now()
	h.deadline, _ = ctx.Deadline()
	h.ctxErr = ctx.Err()
	h.after = time.Now()
	return nil
}

func TestArrivalDispatchGivesPushBackendTwentyFiveSecondBudget(t *testing.T) {
	h := &riderDeadlineHandler{}
	c := newArrivalConsumer(nil, h)
	before := time.Now()
	if !c.dispatchArrivalMessage(context.Background(), "budget", []riderevent.ArrivalEvent{{RouteKey: "route"}}) {
		t.Fatal("successful backend left pending")
	}
	if h.ctxErr != nil || h.deadline.Before(before.Add(25*time.Second)) || h.deadline.After(h.after.Add(25*time.Second)) {
		t.Fatalf("backend deadline=%v, call bracket=[%v,%v], err=%v", h.deadline, before, h.after, h.ctxErr)
	}
}

func TestArrivalGroupCreationFailureKeepsOriginalDiagnostic(t *testing.T) {
	logs := riderContractLogs(t)
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	t.Cleanup(func() { _ = rc.Close() })
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	newArrivalConsumer(rc, &recordingHandler{}).run(ctx)
	riderLoggedCause(t, riderActionLogs(logs, "arrivals", "create_group"), redis.ErrClosed)
}

func TestArrivalReclaimReportsOnlyActiveFailures(t *testing.T) {
	logs := riderContractLogs(t)
	rc := testRedis(t)
	c := newArrivalConsumer(rc, &recordingHandler{})
	if err := c.ensureGroup(context.Background()); err != nil {
		t.Fatal(err)
	}
	c.reclaimIfActive(context.Background())
	if entries := riderActionLogs(logs, "arrivals", "reclaim"); len(entries) != 0 {
		t.Fatalf("successful reclaim reported failure: %+v", entries)
	}
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	c.reclaimIfActive(context.Background())
	riderLoggedCause(t, riderActionLogs(logs, "arrivals", "reclaim"), redis.ErrClosed)
	logs.TakeAll()
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	c.reclaimIfActive(canceled)
	if entries := riderActionLogs(logs, "arrivals", "reclaim"); len(entries) != 0 {
		t.Fatalf("shutdown reported reclaim failure: %+v", entries)
	}
}

func TestArrivalAcknowledgmentFailureRetainsCauseAndMessageID(t *testing.T) {
	logs := riderContractLogs(t)
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	if err := rc.Close(); err != nil {
		t.Fatal(err)
	}
	c := newArrivalConsumer(rc, &recordingHandler{})
	c.acknowledgeArrivalMessage(context.Background(), "123-4")
	entries := riderActionLogs(logs, "arrivals", "ack")
	riderLoggedCause(t, entries, redis.ErrClosed)
	for _, entry := range entries {
		if entry.ContextMap()["id"] == "123-4" {
			return
		}
	}
	t.Fatal("ack failure lost stream message identity")
}

func TestZeroRemainingReminderDemandDoesNotCreatePermanentRedisKey(t *testing.T) {
	rc := riderWorkerTestRedis(t)
	ctx := context.Background()
	key := shared.LiveDemandKey("bus_eta", "Taipei")
	if err := rc.Del(ctx, key).Err(); err != nil {
		t.Fatal(err)
	}
	if got := touchCityDemand(ctx, firebase.RedisDemand{RC: rc}, "TPE", 0); got != 0 {
		t.Fatalf("expired demand touched=%d", got)
	}
	if n := rc.Exists(ctx, key).Val(); n != 0 {
		t.Fatalf("zero TTL produced unbounded demand key, exists=%d", n)
	}
}

func TestHealthMarkerCreationFailureIsDiagnosticAndNonfatal(t *testing.T) {
	logs := riderContractLogs(t)
	parent := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(parent, []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(parent, "healthy")
	newHealthFile(path).touch()
	entries := riderActionLogs(logs, "health", "touch")
	for _, entry := range entries {
		if entry.ContextMap()["path"] != path {
			continue
		}
		for _, field := range entry.Context {
			if err, ok := field.Interface.(*os.PathError); field.Key == "err" && ok && err.Path == path && err.Op == "open" {
				return
			}
		}
	}
	t.Fatalf("health create failure missing original path/error: %+v", entries)
}

func TestClosingRedisReportsFailureWithoutFalseHealthyError(t *testing.T) {
	logs := riderContractLogs(t)
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	closeRiderRedis(rc)
	if entries := riderActionLogs(logs, "redis", "close"); len(entries) != 0 {
		t.Fatalf("successful close reported failure: %+v", entries)
	}
	closeRiderRedis(rc)
	riderLoggedCause(t, riderActionLogs(logs, "redis", "close"), redis.ErrClosed)
}

type riderNoSend struct{ calls int }

func (s *riderNoSend) Send(context.Context, *messaging.Message) error { s.calls++; return nil }

func riderContractCron(t *testing.T, db *pgxpool.Pool, dispatcher *notify.Dispatcher) *cron.Cron {
	t.Helper()
	t.Setenv("TRTC_USERNAME", "")
	t.Setenv("TRTC_PASSWORD", "")
	old := _health
	_health = nil
	t.Cleanup(func() { _health = old })
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	_ = rc.Close()
	r := cron.New(cron.WithSeconds())
	registerRiderJobs(r, rc, db, dispatcher, notify.NewTrackPusher(nil, nil))
	if len(r.Entries()) != 4 {
		t.Fatalf("scheduled jobs=%d", len(r.Entries()))
	}
	return r
}

func riderContractOutbox(t *testing.T, db *pgxpool.Pool) {
	t.Helper()
	_, err := db.Exec(context.Background(), `CREATE TABLE route_alert_outbox(id bigint,route_type text,route_key text,body text,processed_at timestamptz,claimed_until timestamptz,attempts int,created_at timestamptz)`)
	if err != nil {
		t.Fatal(err)
	}
}

func TestScheduledFailuresRetainDatabaseCauseAndDoNotPush(t *testing.T) {
	db, _ := riderWorkerTestPool(t)
	logs := riderContractLogs(t)
	mock, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(mock.Close)
	t.Cleanup(func() {
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Error(err)
		}
	})
	cause := errors.New("scheduled reminders unavailable")
	mock.ExpectQuery("SELECT r.reminder_id").WithArgs(pgxmock.AnyArg(), pgxmock.AnyArg()).WillReturnError(cause)
	sender := &riderNoSend{}
	r := riderContractCron(t, db, notify.NewDispatcher(notify.NewStore(mock), sender))
	r.Entries()[0].Job.Run()
	riderLoggedCause(t, riderActionLogs(logs, "reminders", "fire_scheduled"), cause)
	r.Entries()[1].Job.Run()
	entries := riderActionLogs(logs, "outbox", "drain")
	found := false
	for _, entry := range entries {
		for _, field := range entry.Context {
			var pgErr *pgconn.PgError
			if err, ok := field.Interface.(error); field.Key == "err" && ok && errors.As(err, &pgErr) && pgErr.Code == "42P01" {
				found = true
			}
		}
	}
	if !found || sender.calls != 0 {
		t.Fatalf("outbox missing-table cause=%+v, sends=%d", entries, sender.calls)
	}
}

func TestDisabledPushAndEmptyOutboxDoNotReportScheduledFailure(t *testing.T) {
	db, _ := riderWorkerTestPool(t)
	riderContractOutbox(t, db)
	logs := riderContractLogs(t)
	r := riderContractCron(t, db, nil)
	r.Entries()[0].Job.Run()
	r.Entries()[1].Job.Run()
	for _, pair := range [][2]string{{"reminders", "fire_scheduled"}, {"outbox", "drain"}} {
		if entries := riderActionLogs(logs, pair[0], pair[1]); len(entries) != 0 {
			t.Fatalf("successful tick reported failure: %+v", entries)
		}
	}
}

func TestScheduledPrunePreservesThirtyDayReminderHistoryAndPendingRows(t *testing.T) {
	db, _ := riderWorkerTestPool(t)
	riderContractOutbox(t, db)
	ctx := context.Background()
	if _, err := db.Exec(ctx, `ALTER TABLE firebase_arrival_reminder ADD COLUMN updated_at timestamptz;
 INSERT INTO firebase_arrival_reminder(route_key,status,updated_at) VALUES
 ('old-fired','fired',NOW()-INTERVAL '31 days'),
 ('old-cancelled','cancelled',NOW()-INTERVAL '31 days'),
 ('old-expired','expired',NOW()-INTERVAL '31 days'),
 ('recent-fired','fired',NOW()-INTERVAL '29 days'),
 ('old-pending','pending',NOW()-INTERVAL '31 days'),
 ('future-fired','fired',NOW()+INTERVAL '1 day')`); err != nil {
		t.Fatal(err)
	}
	r := riderContractCron(t, db, nil)
	r.Entries()[3].Job.Run()
	rows, err := db.Query(ctx, `SELECT route_key FROM firebase_arrival_reminder ORDER BY route_key`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var keys []string
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			t.Fatal(err)
		}
		keys = append(keys, key)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(keys, []string{"future-fired", "old-pending", "recent-fired"}) {
		t.Fatalf("history/pending survivors=%v", keys)
	}
}

func TestOutboxClaimsPersistTwoMinuteLease(t *testing.T) {
	db, _ := riderWorkerTestPool(t)
	riderContractOutbox(t, db)
	ctx := context.Background()
	if _, err := db.Exec(ctx, `INSERT INTO route_alert_outbox(id,route_type,route_key,body,attempts,created_at) VALUES(1,'bus','route','alert',0,NOW())`); err != nil {
		t.Fatal(err)
	}
	var before time.Time
	if err := db.QueryRow(ctx, `SELECT clock_timestamp()`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	alerter := &recordingAlerter{}
	n, err := drainRouteAlertOutbox(ctx, db, alerter)
	var after time.Time
	if err := db.QueryRow(ctx, `SELECT clock_timestamp()`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if err != nil || n != 1 {
		t.Fatalf("drain=%d, %v", n, err)
	}
	if !reflect.DeepEqual(alerter.sent, []string{"bus/route"}) {
		t.Fatalf("claimed alert dispatch=%v", alerter.sent)
	}
	var until time.Time
	var attempts int
	var processed bool
	if err := db.QueryRow(ctx, `SELECT claimed_until,attempts,processed_at IS NOT NULL FROM route_alert_outbox WHERE id=1`).Scan(&until, &attempts, &processed); err != nil {
		t.Fatal(err)
	}
	if until.Before(before.Add(2*time.Minute)) || until.After(after.Add(2*time.Minute)) || attempts != 1 || !processed {
		t.Fatalf("claim lease=%v, bracket=[%v,%v], attempts=%d processed=%t", until, before, after, attempts, processed)
	}
}

func TestOutboxPruneFailureReturnsOriginalCauseWithoutSuccess(t *testing.T) {
	logs := riderContractLogs(t)
	mock, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(mock.Close)
	t.Cleanup(func() {
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Error(err)
		}
	})
	cause := errors.New("outbox deletion unavailable")
	mock.ExpectExec("DELETE FROM route_alert_outbox").WithArgs(float64(7 * 24 * 60 * 60)).WillReturnError(cause)
	if err := pruneRouteAlertOutbox(context.Background(), mock); !errors.Is(err, cause) {
		t.Fatalf("prune cause=%v", err)
	}
	if entries := riderActionLogs(logs, "outbox", "prune"); len(entries) != 0 {
		t.Fatalf("failed prune reported completion: %+v", entries)
	}
}

func TestRiderCommandValidationRejectsUnexpectedValuesWithoutStartup(t *testing.T) {
	for _, tc := range []struct {
		args  []string
		valid bool
	}{
		{nil, false}, {[]string{"api"}, true}, {[]string{"worker"}, true},
		{[]string{"unknown"}, false}, {[]string{"api", "worker"}, false}, {[]string{""}, false},
	} {
		if got := validRiderCommand(tc.args); got != tc.valid {
			t.Fatalf("args=%v valid=%t", tc.args, got)
		}
	}
}

func TestRiderServingDiagnosticReportsConfiguredTransport(t *testing.T) {
	logs := riderContractLogs(t)
	for _, dir := range []string{"", "configured-tls"} {
		lis, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		_ = lis.Close()
		shutdown := make(chan struct{})
		if err := serveRiderServers(grpc.NewServer(), &http.Server{Addr: "127.0.0.1:0"}, lis, dir, func() { <-shutdown }); err == nil {
			close(shutdown)
			t.Fatal("closed listener served")
		}
		close(shutdown)
		entries := logs.FilterMessage("serving").TakeAll()
		if len(entries) != 1 || entries[0].ContextMap()["mtls"] != (dir != "") {
			t.Fatalf("configured transport=%q diagnostic=%+v", dir, entries)
		}
		logs.TakeAll()
	}
}
