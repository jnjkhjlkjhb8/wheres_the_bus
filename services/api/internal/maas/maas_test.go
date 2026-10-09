package maas

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/redistest"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/pashagolub/pgxmock/v4"
	redisv9 "github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type maasTDXStore struct {
	token  string
	getErr error
	gets   int32
}

func (s *maasTDXStore) Get(context.Context, string) (string, error) {
	atomic.AddInt32(&s.gets, 1)
	if s.getErr != nil {
		return "", s.getErr
	}
	return s.token, nil
}

func (*maasTDXStore) Set(context.Context, string, string, time.Duration) error { return nil }
func (*maasTDXStore) Del(context.Context, ...string) error                     { return nil }

var errMaasCacheMiss = errors.New("cache miss")

type controlledMaasCache struct {
	mu sync.Mutex

	data map[string][]byte

	getCalls  atomic.Int32
	setCalls  atomic.Int32
	getOnce   sync.Once
	setOnce   sync.Once
	getStart  chan struct{}
	setStart  chan struct{}
	getBlock  <-chan struct{}
	setBlock  <-chan struct{}
	getCtxEnd chan struct{}
	setCtxEnd chan struct{}
}

func newControlledMaasCache() *controlledMaasCache {
	return &controlledMaasCache{data: make(map[string][]byte)}
}

func (c *controlledMaasCache) Get(ctx context.Context, key string) ([]byte, error) {
	c.getCalls.Add(1)
	if c.getStart != nil {
		c.getOnce.Do(func() { close(c.getStart) })
	}
	if c.getBlock != nil {
		select {
		case <-c.getBlock:
		case <-ctx.Done():
			if c.getCtxEnd != nil {
				close(c.getCtxEnd)
			}
			return nil, ctx.Err()
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	value, ok := c.data[key]
	if !ok {
		return nil, errMaasCacheMiss
	}
	return append([]byte(nil), value...), nil
}

func (c *controlledMaasCache) Set(ctx context.Context, key string, value []byte, _ time.Duration) error {
	c.setCalls.Add(1)
	if c.setStart != nil {
		c.setOnce.Do(func() { close(c.setStart) })
	}
	if c.setBlock != nil {
		select {
		case <-c.setBlock:
		case <-ctx.Done():
			if c.setCtxEnd != nil {
				close(c.setCtxEnd)
			}
			return ctx.Err()
		}
	}
	c.mu.Lock()
	c.data[key] = append([]byte(nil), value...)
	c.mu.Unlock()
	return nil
}

type doneObservedContext struct {
	context.Context
	once     sync.Once
	observed chan struct{}
}

type pendingDeadlineContext struct {
	context.Context
	deadline time.Time
}

func (c pendingDeadlineContext) Deadline() (time.Time, bool) { return c.deadline, true }

type fakeTimeoutError struct{}

func (fakeTimeoutError) Error() string   { return "i/o timeout" }
func (fakeTimeoutError) Timeout() bool   { return true }
func (fakeTimeoutError) Temporary() bool { return true }

type commandCompletionHook struct {
	target string
	done   chan struct{}
	once   sync.Once
}

func (h *commandCompletionHook) DialHook(next redisv9.DialHook) redisv9.DialHook {
	return next
}

func (h *commandCompletionHook) ProcessHook(next redisv9.ProcessHook) redisv9.ProcessHook {
	return func(ctx context.Context, command redisv9.Cmder) error {
		err := next(ctx, command)
		if strings.EqualFold(command.Name(), h.target) {
			h.once.Do(func() { close(h.done) })
		}
		return err
	}
}

func (h *commandCompletionHook) ProcessPipelineHook(next redisv9.ProcessPipelineHook) redisv9.ProcessPipelineHook {
	return next
}

func (c *doneObservedContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.observed) })
	return c.Context.Done()
}

func TestMaasCanceledRequestDoesNotRetryOrReachUpstream(t *testing.T) {
	var hits int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer upstream.Close()

	store := &maasTDXStore{token: "tok"}
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: store, IMSKey: shared.TDXLegacyIMSKey})
	client := NewMaasServerWithCache(newControlledMaasCache(), nil, tdx, DefaultMaasSharedWorkConfig).maasClient.SetBaseURL(upstream.URL)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	started := time.Now()
	_, err := client.R().SetContext(ctx).Get("/routing")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("MaaS canceled error = %v, want context.Canceled", err)
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("canceled MaaS request took %v", elapsed)
	}
	if got := atomic.LoadInt32(&hits); got != 0 {
		t.Fatalf("upstream hits = %d, want 0", got)
	}
}

func TestMaasAuthCacheErrorIsNotRetried(t *testing.T) {
	var hits int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer upstream.Close()

	cacheErr := errors.New("token cache unavailable")
	store := &maasTDXStore{getErr: cacheErr}
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: store, IMSKey: shared.TDXLegacyIMSKey})
	client := NewMaasServerWithCache(newControlledMaasCache(), nil, tdx, DefaultMaasSharedWorkConfig).maasClient.
		SetBaseURL(upstream.URL).
		SetRetryWaitTime(time.Nanosecond).
		SetRetryMaxWaitTime(time.Nanosecond)
	_, err := client.R().SetContext(context.Background()).Get("/routing")
	if !errors.Is(err, cacheErr) {
		t.Fatalf("MaaS auth error = %v, want %v", err, cacheErr)
	}
	if got := atomic.LoadInt32(&store.gets); got != 1 {
		t.Fatalf("token cache reads = %d, want 1 (no retry)", got)
	}
	if got := atomic.LoadInt32(&hits); got != 0 {
		t.Fatalf("upstream hits = %d, want 0", got)
	}
}

func TestRedisContextErrorHandlesSocketDeadlineTimerRace(t *testing.T) {
	timeoutErr := fakeTimeoutError{}
	pastDeadline := pendingDeadlineContext{Context: context.Background(), deadline: time.Now().Add(-time.Second)}
	if err := redisContextError(pastDeadline, timeoutErr); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("elapsed context deadline error = %v, want %v", err, context.DeadlineExceeded)
	}
	futureDeadline := pendingDeadlineContext{Context: context.Background(), deadline: time.Now().Add(time.Hour)}
	if err := redisContextError(futureDeadline, timeoutErr); !errors.Is(err, timeoutErr) {
		t.Fatalf("early Redis timeout error = %v, want original %v", err, timeoutErr)
	}
}

func TestRedisMaasCacheCommandsEndBeforeContextErrorReturns(t *testing.T) {
	for _, test := range []struct {
		name      string
		command   string
		invoke    func(context.Context, *RedisMaasCache) error
		newCtx    func() (context.Context, context.CancelFunc)
		wantError error
	}{
		{
			name: "Get deadline", command: "get",
			invoke: func(ctx context.Context, cache *RedisMaasCache) error {
				_, err := cache.Get(ctx, "blocked")
				return err
			},
			newCtx: func() (context.Context, context.CancelFunc) {
				return context.WithTimeout(context.Background(), 80*time.Millisecond)
			},
			wantError: context.DeadlineExceeded,
		},
		{
			name: "Set deadline", command: "set",
			invoke: func(ctx context.Context, cache *RedisMaasCache) error {
				return cache.Set(ctx, "blocked", []byte("value"), time.Minute)
			},
			newCtx: func() (context.Context, context.CancelFunc) {
				return context.WithTimeout(context.Background(), 80*time.Millisecond)
			},
			wantError: context.DeadlineExceeded,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			endpoint := redistest.Start(t, test.command)
			cache := NewRedisMaasCache(&redisv9.Options{
				Network: "tcp", Addr: endpoint.Address, MaxRetries: -1, ContextTimeoutEnabled: true,
				DialTimeout: time.Second, ReadTimeout: -1, WriteTimeout: -1,
				PoolSize: 1, PoolTimeout: time.Second,
			})
			defer func() { _ = cache.Close() }()
			processDone := make(chan struct{})
			cache.client.AddHook(&commandCompletionHook{target: test.command, done: processDone})
			ctx, cancel := test.newCtx()
			defer cancel()
			result := make(chan error, 1)
			go func() { result <- test.invoke(ctx, cache) }()
			select {
			case <-endpoint.CommandStarted:
			case <-time.After(time.Second):
				t.Fatal("blocking Redis command never reached the TCP seam")
			}
			var err error
			select {
			case err = <-result:
			case <-time.After(time.Second):
				t.Fatal("cache command did not return after context termination")
			}
			if !errors.Is(err, test.wantError) {
				t.Fatalf("cache command error = %v, want %v", err, test.wantError)
			}
			select {
			case <-processDone:
			default:
				t.Fatal("cache returned before the underlying v9 command processor ended")
			}
			select {
			case <-endpoint.ConnectionStopped:
			case <-time.After(time.Second):
				t.Fatal("context termination left a detached Redis command on the socket")
			}
		})
	}
}

func TestRedisMaasCacheCommandRetainsSharedPermitUntilTermination(t *testing.T) {
	endpoint := redistest.Start(t, "get")
	cache := NewRedisMaasCache(&redisv9.Options{
		Network: "tcp", Addr: endpoint.Address, MaxRetries: -1, ContextTimeoutEnabled: true,
		DialTimeout: time.Second, ReadTimeout: -1, WriteTimeout: -1,
		PoolSize: 1, PoolTimeout: time.Second,
	})
	defer func() { _ = cache.Close() }()
	processDone := make(chan struct{})
	cache.client.AddHook(&commandCompletionHook{target: "get", done: processDone})
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	server := NewMaasServerWithCache(cache, nil, tdx, maasSharedWorkConfig{MaxConcurrent: 1, Timeout: 80 * time.Millisecond})
	request := &pb.MaasPlanRequest{FromLat: 25, FromLon: 121.5, ToLat: 25.1, ToLon: 121.6, Date: "2027-01-01", Time: "08:00"}
	firstDone := make(chan error, 1)
	go func() {
		_, err := server.Plan(context.Background(), request)
		firstDone <- err
	}()
	select {
	case <-endpoint.CommandStarted:
	case <-time.After(time.Second):
		t.Fatal("shared Redis command never reached the TCP seam")
	}
	other := proto.Clone(request).(*pb.MaasPlanRequest)
	other.ToLat += 0.01
	if _, err := server.Plan(context.Background(), other); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("shared permit released while Redis command was active: code=%v error=%v", status.Code(err), err)
	}
	if err := <-firstDone; status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("bounded shared Redis work code = %v, want %v (error=%v)", status.Code(err), codes.DeadlineExceeded, err)
	}
	select {
	case <-processDone:
	default:
		t.Fatal("shared flight returned before Redis command termination")
	}
	if got := len(server.workSlots); got != 0 {
		t.Fatalf("shared permit leaked after Redis command termination: %d", got)
	}
}

func TestMaasTimeParam(t *testing.T) {
	now := time.Date(2026, 7, 11, 23, 0, 0, 0, time.Local)
	layout := "2006-01-02T15:04:05"

	// TDX requires both depart and arrival present (else 40001); every case
	// must return the two equal and non-empty.
	assertBoth := func(t *testing.T, depart, arrival, want string) {
		t.Helper()
		if depart != arrival {
			t.Fatalf("depart %q != arrival %q, TDX needs both equal", depart, arrival)
		}
		if want != "" && depart != want {
			t.Fatalf("got %q, want %q", depart, want)
		}
	}

	t.Run("arriveBy sends the requested time with padded seconds", func(t *testing.T) {
		d, a := maasTimeParam("2026-07-12", "08:30", true, now)
		assertBoth(t, d, a, "2026-07-12T08:30:00")
	})

	t.Run("future depart is passed through unchanged", func(t *testing.T) {
		d, a := maasTimeParam("2026-07-11", "23:30", false, now)
		assertBoth(t, d, a, "2026-07-11T23:30:00")
	})

	for _, tt := range []struct{ name, date, tm string }{
		{"now", "2026-07-11", "23:00"},
		{"past", "2026-07-11", "22:00"},
	} {
		t.Run("depart "+tt.name+" is bumped into the future", func(t *testing.T) {
			d, a := maasTimeParam(tt.date, tt.tm, false, now)
			assertBoth(t, d, a, "")
			got, err := time.ParseInLocation(layout, d, time.Local)
			if err != nil {
				t.Fatalf("unparseable depart %q: %v", d, err)
			}
			if !got.After(now) {
				t.Fatalf("depart %v not after now %v", got, now)
			}
		})
	}

	t.Run("unparseable time falls through unchanged", func(t *testing.T) {
		d, a := maasTimeParam("", "", false, now)
		assertBoth(t, d, a, "T")
	})
}

func TestConvertBatchesIdentityAndFareQueries(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery(`(?s)WITH input AS.*bus_station_stop_map`).
		WithArgs(
			[]int32{0, 2, 3},
			[]string{"A", "C", "E"},
			[]string{"B", "D", "F"},
			[]string{"1", "2", "3"},
			[]string{"1", "2", "3"},
			[]string{"", "", ""},
		).
		WillReturnRows(pgxmock.NewRows([]string{
			"section_index", "sub_route_uid", "direction", "departure_stop_uid", "arrival_stop_uid", "match_count",
		}).
			AddRow(int32(0), "BUS-1", int32(0), "STOP-A", "STOP-B", int64(1)).
			AddRow(int32(2), "BUS-2", int32(1), "STOP-C", "STOP-D", int64(2)))
	db.ExpectQuery(`(?s)WITH input AS.*destination\.system = origin\.system.*m\.system = origin\.system.*MIN\(fare\).*WHERE fare > 0`).
		WithArgs(
			[]int32{1, 4, 5, 6},
			[]string{"mrt", "tra", "thsr", "subway"},
			[]string{"台北", "台北", "台北", "西門"},
			[]string{"西門", "台中", "左營", "龍山寺"},
		).
		WillReturnRows(pgxmock.NewRows([]string{"section_index", "fare"}).
			AddRow(int32(1), int32(25)).
			AddRow(int32(1), int32(20)).
			AddRow(int32(4), int32(41)).
			AddRow(int32(4), int32(41)).
			AddRow(int32(5), int32(0)).
			AddRow(int32(5), int32(700)).
			AddRow(int32(6), int32(-10)).
			AddRow(int32(6), int32(30)))

	section := func(mode, name, from, to string) tdxSection {
		return tdxSection{
			Type:      "transit",
			Transport: tdxTransport{Mode: mode, Name: name, ShortName: name},
			Departure: tdxPlaceInfo{Place: tdxPlace{Name: from}},
			Arrival:   tdxPlaceInfo{Place: tdxPlace{Name: to}},
		}
	}
	api := &tdxAPIResponse{}
	api.Data.Routes = []tdxRoute{{Sections: []tdxSection{
		section("BUS", "1", "A", "B"),
		section("MRT", "", "台北", "西門"),
		section("HighwayBus", "2", "C", "D"),
		section("BUS", "3", "E", "F"),
		section("TRA", "", "台北", "台中"),
		section("THSR", "", "台北", "左營"),
		section("SUBWAY", "", "西門", "龍山寺"),
	}}}

	out := convert(context.Background(), db, nil, api)
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatalf("database queries were not batched to a constant count: %v", err)
	}
	sections := out.GetRoutes()[0].GetSections()
	if got := sections[0].GetNotificationIdentity().GetRouteKey(); got != "BUS-1" {
		t.Fatalf("first bus route key = %q, want BUS-1", got)
	}
	if sections[2].GetNotificationIdentity().GetSupported() {
		t.Fatalf("ambiguous second bus identity must be unsupported: %v", sections[2].GetNotificationIdentity())
	}
	if sections[3].GetNotificationIdentity().GetSupported() {
		t.Fatalf("unmatched third bus identity must be unsupported: %v", sections[3].GetNotificationIdentity())
	}
	wantFares := map[int]int32{1: 20, 4: 41, 5: 700, 6: 30}
	for index, want := range wantFares {
		if got := sections[index].GetFare(); got != want {
			t.Fatalf("section %d fare = %d, want %d", index, got, want)
		}
	}
	if got := out.GetRoutes()[0].GetTotalFare(); got != 791 {
		t.Fatalf("total fare = %d, want 791", got)
	}
}

type cancelAfterRateContext struct {
	context.Context
	errCalls atomic.Int32
}

func (c *cancelAfterRateContext) Err() error {
	if c.errCalls.Add(1) >= 2 {
		return context.Canceled
	}
	return nil
}

func TestMaasResourceInterceptorChecksCancellationBeforeAndAfterRateAccounting(t *testing.T) {
	info := &grpc.UnaryServerInfo{FullMethod: pb.MaasService_Plan_FullMethodName}
	handler := func(context.Context, any) (any, error) { return "ok", nil }

	t.Run("already canceled does not consume rate quota", func(t *testing.T) {
		interceptor := MaasResourceInterceptor(ratelimit.New(), MaasResourceConfig{
			RateLimit: 1, RateWindow: time.Minute,
		})
		peerCtx := limiterContext("203.0.113.40:1234")
		canceled, cancel := context.WithCancel(peerCtx)
		cancel()
		if _, err := interceptor(canceled, nil, info, handler); status.Code(err) != codes.Canceled {
			t.Fatalf("canceled call code = %v", status.Code(err))
		}
		if _, err := interceptor(peerCtx, nil, info, handler); err != nil {
			t.Fatalf("canceled call consumed quota: %v", err)
		}
	})

	t.Run("cancellation immediately after rate accounting skips handler", func(t *testing.T) {
		interceptor := MaasResourceInterceptor(ratelimit.New(), MaasResourceConfig{
			RateLimit: 10, RateWindow: time.Minute,
		})
		ctx := &cancelAfterRateContext{Context: limiterContext("203.0.113.41:1234")}
		called := false
		_, err := interceptor(ctx, nil, info, func(context.Context, any) (any, error) {
			called = true
			return "unexpected", nil
		})
		if status.Code(err) != codes.Canceled || called {
			t.Fatalf("post-rate cancellation = (code=%v called=%v)", status.Code(err), called)
		}
	})
}

func TestMaasSharedFlightSurvivesLeaderCancellationAndOwnsPermit(t *testing.T) {
	upstreamStarted := make(chan struct{})
	releaseUpstream := make(chan struct{})
	var hits, active, peak atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		current := active.Add(1)
		defer active.Add(-1)
		for {
			observed := peak.Load()
			if current <= observed || peak.CompareAndSwap(observed, current) {
				break
			}
		}
		select {
		case <-upstreamStarted:
		default:
			close(upstreamStarted)
		}
		<-releaseUpstream
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"result":"success","data":{"routes":[]}}`)
	}))
	defer upstream.Close()

	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	cache := newControlledMaasCache()
	server := NewMaasServerWithCache(cache, nil, tdx, maasSharedWorkConfig{MaxConcurrent: 1, Timeout: 2 * time.Second})
	server.maasClient.SetBaseURL(upstream.URL).SetRetryCount(0)
	interceptor := MaasResourceInterceptor(ratelimit.New(), MaasResourceConfig{
		RateLimit: 100, RateWindow: time.Minute,
	})
	info := &grpc.UnaryServerInfo{FullMethod: pb.MaasService_Plan_FullMethodName}
	req := &pb.MaasPlanRequest{FromLat: 25.0, FromLon: 121.5, ToLat: 25.1, ToLon: 121.6, Date: "2027-01-01", Time: "08:00"}
	planHandler := func(ctx context.Context, request any) (any, error) {
		return server.Plan(ctx, request.(*pb.MaasPlanRequest))
	}

	leaderCtx, cancelLeader := context.WithCancel(limiterContext("203.0.113.50:1234"))
	leaderDone := make(chan error, 1)
	go func() {
		_, err := interceptor(leaderCtx, req, info, planHandler)
		leaderDone <- err
	}()
	<-upstreamStarted

	followerJoined := make(chan struct{})
	followerCtx := &doneObservedContext{
		Context:  limiterContext("203.0.113.51:1234"),
		observed: followerJoined,
	}
	followerDone := make(chan error, 1)
	go func() {
		_, err := interceptor(followerCtx, req, info, planHandler)
		followerDone <- err
	}()
	<-followerJoined
	cancelLeader()

	select {
	case err := <-leaderDone:
		if status.Code(err) != codes.Canceled {
			close(releaseUpstream)
			t.Fatalf("leader code = %v, want %v", status.Code(err), codes.Canceled)
		}
	case <-time.After(250 * time.Millisecond):
		close(releaseUpstream)
		t.Fatal("canceled leader did not return promptly")
	}

	otherReq := proto.Clone(req).(*pb.MaasPlanRequest)
	otherReq.ToLat += 0.01
	if _, err := interceptor(limiterContext("203.0.113.52:1234"), otherReq, info, planHandler); status.Code(err) != codes.ResourceExhausted {
		close(releaseUpstream)
		t.Fatalf("leader cancellation released active shared-work permit: code=%v error=%v", status.Code(err), err)
	}

	select {
	case err := <-followerDone:
		close(releaseUpstream)
		t.Fatalf("follower finished before shared work release: %v", err)
	default:
	}
	close(releaseUpstream)
	if err := <-followerDone; err != nil {
		t.Fatalf("valid follower failed after leader cancellation: %v", err)
	}
	if got := cache.getCalls.Load(); got != 1 {
		t.Fatalf("same-key callers performed %d cache Gets, want one shared Get", got)
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("same-key callers performed %d upstream requests, want one", got)
	}
	if got := peak.Load(); got != 1 {
		t.Fatalf("peak upstream concurrency = %d, want 1", got)
	}

	thirdReq := proto.Clone(req).(*pb.MaasPlanRequest)
	thirdReq.ToLat += 0.02
	if _, err := interceptor(limiterContext("203.0.113.53:1234"), thirdReq, info, planHandler); err != nil {
		t.Fatalf("shared-work permit leaked after completion: %v", err)
	}
	if got := peak.Load(); got != 1 {
		t.Fatalf("shared-work cap was exceeded: peak=%d", got)
	}
}

func TestMaasSharedCacheGetAndSetHonorContexts(t *testing.T) {
	request := &pb.MaasPlanRequest{FromLat: 25.0, FromLon: 121.5, ToLat: 25.1, ToLon: 121.6, Date: "2027-01-01", Time: "08:00"}
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})

	t.Run("caller cancellation returns while shared Get remains bounded", func(t *testing.T) {
		getStarted := make(chan struct{})
		getRelease := make(chan struct{})
		getCtxEnd := make(chan struct{})
		cache := newControlledMaasCache()
		cache.getStart, cache.getBlock, cache.getCtxEnd = getStarted, getRelease, getCtxEnd
		server := NewMaasServerWithCache(cache, nil, tdx, maasSharedWorkConfig{MaxConcurrent: 1, Timeout: 40 * time.Millisecond})
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() {
			_, err := server.Plan(ctx, request)
			done <- err
		}()
		<-getStarted
		cancel()
		select {
		case err := <-done:
			if status.Code(err) != codes.Canceled {
				t.Fatalf("cache Get caller cancellation code = %v", status.Code(err))
			}
		case <-time.After(250 * time.Millisecond):
			t.Fatal("caller cancellation stayed blocked in cache Get")
		}
		select {
		case <-getCtxEnd:
		case <-time.After(250 * time.Millisecond):
			t.Fatal("shared cache Get outlived its bounded context")
		}
	})

	t.Run("shared Set timeout returns DeadlineExceeded and releases permit", func(t *testing.T) {
		setStarted := make(chan struct{})
		setRelease := make(chan struct{})
		setCtxEnd := make(chan struct{})
		cache := newControlledMaasCache()
		cache.setStart, cache.setBlock, cache.setCtxEnd = setStarted, setRelease, setCtxEnd
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"result":"success","data":{"routes":[]}}`)
		}))
		defer upstream.Close()
		server := NewMaasServerWithCache(cache, nil, tdx, maasSharedWorkConfig{MaxConcurrent: 1, Timeout: 40 * time.Millisecond})
		server.maasClient.SetBaseURL(upstream.URL).SetRetryCount(0)
		done := make(chan error, 1)
		go func() {
			_, err := server.Plan(context.Background(), request)
			done <- err
		}()
		<-setStarted
		select {
		case <-setCtxEnd:
		case <-time.After(250 * time.Millisecond):
			t.Fatal("cache Set outlived the shared timeout")
		}
		if err := <-done; status.Code(err) != codes.DeadlineExceeded {
			t.Fatalf("cache Set timeout code = %v, want %v (error=%v)", status.Code(err), codes.DeadlineExceeded, err)
		}
		close(setRelease)
		other := proto.Clone(request).(*pb.MaasPlanRequest)
		other.ToLat += 0.01
		if _, err := server.Plan(context.Background(), other); err != nil {
			t.Fatalf("shared-work permit leaked after Set timeout: %v", err)
		}
	})
}

func TestMaasServerCloseJoinsFlightAfterCallerCancels(t *testing.T) {
	getStarted := make(chan struct{})
	getRelease := make(chan struct{}) // deliberately never closed by the test
	getCtxEnd := make(chan struct{})
	cache := newControlledMaasCache()
	cache.getStart, cache.getBlock, cache.getCtxEnd = getStarted, getRelease, getCtxEnd
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	server := NewMaasServerWithCache(cache, nil, tdx, maasSharedWorkConfig{MaxConcurrent: 1, Timeout: 5 * time.Second})

	request := &pb.MaasPlanRequest{FromLat: 25, FromLon: 121.5, ToLat: 25.1, ToLon: 121.6, Date: "2027-01-01", Time: "08:00"}
	callerCtx, cancelCaller := context.WithCancel(context.Background())
	planDone := make(chan error, 1)
	go func() {
		_, err := server.Plan(callerCtx, request)
		planDone <- err
	}()
	<-getStarted
	cancelCaller()
	select {
	case err := <-planDone:
		if status.Code(err) != codes.Canceled {
			t.Fatalf("caller cancellation code = %v", status.Code(err))
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("caller cancellation did not return promptly")
	}

	// The RPC caller is gone, but the shared flight is still blocked in the
	// cache Get (that is the point of singleflight). Shutdown must cancel and
	// join it before returning.
	closeDone := make(chan struct{})
	go func() {
		server.Close()
		close(closeDone)
	}()
	select {
	case <-getCtxEnd:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("Close did not cancel the active shared flight's lifecycle context")
	}
	select {
	case <-closeDone:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("Close did not join the shared flight before returning")
	}
}

func TestMaasServerCloseVersusPlanRaceLeavesNoLeakedPermitOrCacheCommand(t *testing.T) {
	cache := newControlledMaasCache()
	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"result":"success","data":{"routes":[]}}`)
	}))
	defer upstream.Close()
	// MaxConcurrent covers every attempt so the shared-work permit never runs
	// out; the only rejection this test exercises is the closing gate.
	const attempts = 50
	server := NewMaasServerWithCache(cache, nil, tdx, maasSharedWorkConfig{MaxConcurrent: attempts, Timeout: time.Second})
	server.maasClient.SetBaseURL(upstream.URL).SetRetryCount(0)

	var wg sync.WaitGroup
	errs := make([]error, attempts)
	for i := range attempts {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			req := &pb.MaasPlanRequest{
				FromLat: 25, FromLon: 121.5, ToLat: 25.1, ToLon: 121.6 + float64(i)*0.001,
				Date: "2027-01-01", Time: "08:00",
			}
			_, errs[i] = server.Plan(context.Background(), req)
		}(i)
	}
	server.Close()
	wg.Wait()

	for i, err := range errs {
		code := status.Code(err)
		if err != nil && code != codes.Unavailable && code != codes.Canceled && code != codes.DeadlineExceeded {
			t.Fatalf("attempt %d unexpected error: %v", i, err)
		}
	}
	if got := len(server.workSlots); got != 0 {
		t.Fatalf("shared-work permit leaked after Close/Plan race: %d", got)
	}

	getCallsAfterRace := cache.getCalls.Load()
	postCloseReq := &pb.MaasPlanRequest{FromLat: 1, FromLon: 1, ToLat: 2, ToLon: 2, Date: "2027-01-01", Time: "08:00"}
	if _, err := server.Plan(context.Background(), postCloseReq); status.Code(err) != codes.Unavailable {
		t.Fatalf("post-close Plan code = %v, want %v", status.Code(err), codes.Unavailable)
	}
	if got := cache.getCalls.Load(); got != getCallsAfterRace {
		t.Fatalf("post-close Plan reached the cache: calls %d -> %d", getCallsAfterRace, got)
	}
}

// recordingPlanStream captures every MaasPlanUpdate PlanStream sends, so a test
// can assert on the staging rather than only the final content.
type recordingPlanStream struct {
	grpc.ServerStreamingServer[pb.MaasPlanUpdate]
	ctx     context.Context
	updates []*pb.MaasPlanUpdate
}

func (s *recordingPlanStream) Context() context.Context { return s.ctx }

func (s *recordingPlanStream) Send(update *pb.MaasPlanUpdate) error {
	// The two sends carry the same message object, mutated in between, so the
	// recording has to be a snapshot — otherwise both entries would read as the
	// enriched one and the staging assertion would pass vacuously.
	s.updates = append(s.updates, proto.Clone(update).(*pb.MaasPlanUpdate))
	return nil
}

const _maasStreamTDXRoute = `{"result":"success","data":{"routes":[{
  "travel_time":1500,"start_time":"2027-01-01T08:00:00","end_time":"2027-01-01T08:25:00","transfers":0,
  "sections":[{
    "type":"pedestrian","travelSummary":{"duration":600,"length":800},
    "transport":{"mode":"pedestrian"},
    "departure":{"time":"2027-01-01T08:00:00","place":{"name":"起點","location":{"lat":25.00,"lng":121.50}}},
    "arrival":{"time":"2027-01-01T08:10:00","place":{"name":"終點","location":{"lat":25.02,"lng":121.52}}}
  }]}]}}`

// The routes must reach the rider before the map geometry is paid for: the
// first update carries the itinerary with no walkPath, the second the same
// route with OSRM's path attached.
func TestPlanStreamSendsRoutesBeforeGeometry(t *testing.T) {
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, _maasStreamTDXRoute)
	}))
	defer upstream.Close()

	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	cache := newControlledMaasCache()
	server := NewMaasServerWithCache(cache, nil, tdx, DefaultMaasSharedWorkConfig)
	server.maasClient.SetBaseURL(upstream.URL).SetRetryCount(0)
	server.osrmClient = osrmClientReturning(200, _osrmTransferRoute)
	defer server.Close()

	req := &pb.MaasPlanRequest{
		FromLat: 25.0, FromLon: 121.5, ToLat: 25.02, ToLon: 121.52,
		Date: "2027-01-01", Time: "08:00",
	}
	stream := &recordingPlanStream{ctx: context.Background()}
	if err := server.PlanStream(req, stream); err != nil {
		t.Fatalf("PlanStream: %v", err)
	}

	if len(stream.updates) != 2 {
		t.Fatalf("updates = %d, want 2", len(stream.updates))
	}
	first, last := stream.updates[0], stream.updates[1]
	if first.Complete {
		t.Fatal("first update must not be marked complete")
	}
	if len(first.Plan.Routes) != 1 || first.Plan.Routes[0].TravelTime != 1500 {
		t.Fatalf("first update routes = %+v, want one 1500s route", first.Plan.Routes)
	}
	if got := first.Plan.Routes[0].Sections[0].Departure.Name; got != "起點" {
		t.Fatalf("first update departure = %q, want 起點", got)
	}
	if len(first.Plan.Routes[0].Sections[0].WalkPath) != 0 {
		t.Fatal("first update must not carry map geometry")
	}
	if !last.Complete {
		t.Fatal("last update must be marked complete")
	}
	if len(last.Plan.Routes[0].Sections[0].WalkPath) != 3 {
		t.Fatalf("walkPath len = %d, want 3 on the complete update",
			len(last.Plan.Routes[0].Sections[0].WalkPath))
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream hits = %d, want 1", got)
	}
}

// A cached plan is already geometry-complete, so it answers in one message and
// never reaches TDX.
func TestPlanStreamCacheHitSendsSingleCompleteUpdate(t *testing.T) {
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, _maasStreamTDXRoute)
	}))
	defer upstream.Close()

	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	cache := newControlledMaasCache()
	server := NewMaasServerWithCache(cache, nil, tdx, DefaultMaasSharedWorkConfig)
	server.maasClient.SetBaseURL(upstream.URL).SetRetryCount(0)
	server.osrmClient = osrmClientReturning(200, _osrmTransferRoute)
	defer server.Close()

	req := &pb.MaasPlanRequest{
		FromLat: 25.0, FromLon: 121.5, ToLat: 25.02, ToLon: 121.52,
		Date: "2027-01-01", Time: "08:00",
	}
	if err := server.PlanStream(req, &recordingPlanStream{ctx: context.Background()}); err != nil {
		t.Fatalf("first PlanStream: %v", err)
	}

	second := &recordingPlanStream{ctx: context.Background()}
	if err := server.PlanStream(req, second); err != nil {
		t.Fatalf("second PlanStream: %v", err)
	}
	if len(second.updates) != 1 || !second.updates[0].Complete {
		t.Fatalf("cache hit updates = %+v, want one complete update", second.updates)
	}
	if len(second.updates[0].Plan.Routes[0].Sections[0].WalkPath) != 3 {
		t.Fatal("cache hit must carry the enriched geometry")
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream hits = %d, want 1 (second call served from cache)", got)
	}
}

// TDX answering 404 is an empty result, not a router fault: the stream ends
// with NotFound and no partial update is sent.
func TestPlanStreamMapsNoRouteToNotFound(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer upstream.Close()

	tdx := shared.NewTDXClient(shared.TDXConfig{Store: &maasTDXStore{token: "tok"}, IMSKey: shared.TDXLegacyIMSKey})
	server := NewMaasServerWithCache(newControlledMaasCache(), nil, tdx, DefaultMaasSharedWorkConfig)
	server.maasClient.SetBaseURL(upstream.URL).SetRetryCount(0)
	defer server.Close()

	stream := &recordingPlanStream{ctx: context.Background()}
	err := server.PlanStream(&pb.MaasPlanRequest{Date: "2027-01-01", Time: "08:00"}, stream)
	if status.Code(err) != codes.NotFound {
		t.Fatalf("PlanStream error = %v, want NotFound", err)
	}
	if len(stream.updates) != 0 {
		t.Fatalf("updates = %d, want 0", len(stream.updates))
	}
}

// The TDX quota is per caller, not per method: spending it on plan must leave
// nothing for planStream. Without a shared bucket the streaming method would
// hand every caller a second allowance.
func TestMaasQuotaIsSharedBetweenPlanAndPlanStream(t *testing.T) {
	rl := ratelimit.New()
	config := MaasResourceConfig{RateLimit: 1, RateWindow: time.Minute}
	unary := MaasResourceInterceptor(rl, config)
	streamed := MaasResourceStreamInterceptor(rl, config)
	ctx := limiterContext("203.0.113.77:5555")

	_, err := unary(ctx, &pb.MaasPlanRequest{},
		&grpc.UnaryServerInfo{FullMethod: pb.MaasService_Plan_FullMethodName},
		func(context.Context, any) (any, error) { return "ok", nil })
	if err != nil {
		t.Fatalf("first plan = %v, want allowed", err)
	}

	called := false
	err = streamed(nil, &recordingPlanStream{ctx: ctx},
		&grpc.StreamServerInfo{FullMethod: pb.MaasService_PlanStream_FullMethodName},
		func(any, grpc.ServerStream) error { called = true; return nil })
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("planStream after quota spent = %v, want ResourceExhausted", err)
	}
	if called {
		t.Fatal("planStream handler ran despite exhausted quota")
	}
}

// Methods outside the plan family are none of this interceptor's business.
func TestMaasResourceStreamInterceptorIgnoresOtherMethods(t *testing.T) {
	rl := ratelimit.New()
	streamed := MaasResourceStreamInterceptor(rl, MaasResourceConfig{RateLimit: 0, RateWindow: time.Minute})
	called := false
	err := streamed(nil, &recordingPlanStream{ctx: limiterContext("203.0.113.78:5555")},
		&grpc.StreamServerInfo{FullMethod: "/Bus_Route_Service/Live"},
		func(any, grpc.ServerStream) error { called = true; return nil })
	if err != nil || !called {
		t.Fatalf("unrelated stream = (err=%v called=%v), want passthrough", err, called)
	}
}

type limiterTestAddr string

func (a limiterTestAddr) Network() string { return "tcp" }
func (a limiterTestAddr) String() string  { return string(a) }

// limiterContext builds a peer-bearing context so quota tests can act as a
// specific caller. core keeps its own copy for the limiter's own tests.
func limiterContext(address string) context.Context {
	return peer.NewContext(context.Background(), &peer.Peer{Addr: limiterTestAddr(address)})
}
