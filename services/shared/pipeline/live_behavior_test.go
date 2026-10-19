package pipeline

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

type sourceFunc func(context.Context, string, string) (*shared.TDXFetch, error)

func (f sourceFunc) Fetch(ctx context.Context, url, name string) (*shared.TDXFetch, error) {
	return f(ctx, url, name)
}

type refreshSink struct {
	LiveSink
	patterns []TTLPattern
	owner    string
	ttl      time.Duration
	err      error
}

func (s *refreshSink) RefreshTTL(_ context.Context, patterns []TTLPattern) error {
	s.patterns = patterns
	return s.err
}

func (s *refreshSink) RefreshOwnedTTL(_ context.Context, owner string, ttl time.Duration) error {
	s.owner, s.ttl = owner, ttl
	return s.err
}

type pipelineTestContextKey struct{}

func TestBoundFetchPreservesResultAndRefreshPriority(t *testing.T) {
	ctx := context.WithValue(context.Background(), pipelineTestContextKey{}, "context")
	wantErr := errors.New("fetch failed")
	for _, tc := range []struct {
		fetch *shared.TDXFetch
		err   error
	}{
		{nil, nil}, {nil, wantErr}, {&shared.TDXFetch{Modified: true}, nil},
		{&shared.TDXFetch{}, wantErr},
	} {
		sink := &refreshSink{}
		source := sourceFunc(func(gotCtx context.Context, url, name string) (*shared.TDXFetch, error) {
			if gotCtx != ctx || url != "/probe" || name != "city" {
				t.Fatal("fetch identity changed")
			}
			return tc.fetch, tc.err
		})
		got, err := BindFetch(source, sink, LiveSpec{OwnedKey: func(string) string { return "owner" }})(ctx, "/probe", "city")
		if got != tc.fetch || !errors.Is(err, tc.err) || sink.owner != "" {
			t.Fatalf("passthrough result=%v error=%v owner=%q", got, err, sink.owner)
		}
	}
	response := &shared.TDXFetch{}
	source := sourceFunc(func(context.Context, string, string) (*shared.TDXFetch, error) { return response, nil })
	patterns := []TTLPattern{{Pattern: "probe:*", TTL: time.Minute}}
	patternSpec := LiveSpec{TTLPatterns: func(name string) []TTLPattern {
		if name != "city" {
			t.Fatal(name)
		}
		return patterns
	}}
	sink := &refreshSink{}
	got, err := BindFetch(source, sink, patternSpec)(ctx, "/probe", "city")
	if got != response || err != nil || !reflect.DeepEqual(sink.patterns, patterns) {
		t.Fatalf("refresh result=%v error=%v patterns=%v", got, err, sink.patterns)
	}
	sink.err = wantErr
	got, err = BindFetch(source, sink, patternSpec)(ctx, "/probe", "city")
	if got != nil || !errors.Is(err, wantErr) {
		t.Fatalf("refresh failure result=%v error=%v", got, err)
	}
	sink = &refreshSink{}
	patternSpec.OwnedKey = func(name string) string { return "owned:" + name }
	patternSpec.OwnedTTL = 42 * time.Second
	got, err = BindFetch(source, sink, patternSpec)(ctx, "/probe", "city")
	if err != nil || got != response || sink.owner != "owned:city" || sink.ttl != 42*time.Second || sink.patterns != nil {
		t.Fatalf("owned priority sink=%+v error=%v", sink, err)
	}
	if got, err := BindFetch(source, sink, LiveSpec{})(ctx, "/probe", "city"); got != response || err != nil {
		t.Fatalf("unconfigured result=%v error=%v", got, err)
	}
}

func TestOwnedRefreshFailureInvalidatesMarker(t *testing.T) {
	refreshErr, invalidateErr := errors.New("expired data"), errors.New("marker store down")
	for _, failure := range []error{nil, invalidateErr} {
		calls := 0
		response := &shared.TDXFetch{Invalidate: func() error { calls++; return failure }}
		source := sourceFunc(func(context.Context, string, string) (*shared.TDXFetch, error) { return response, nil })
		sink := &refreshSink{err: refreshErr}
		result, err := BindFetch(source, sink, LiveSpec{OwnedKey: func(string) string { return "owner" }})(context.Background(), "/probe", "city")
		if result != nil || calls != 1 || !errors.Is(err, refreshErr) || failure != nil && !errors.Is(err, failure) {
			t.Fatalf("result=%v invalidations=%d error=%v", result, calls, err)
		}
		if failure != nil && !errMentions(err, "invalidate marker after owned-key refresh failure") {
			t.Fatalf("marker failure lost context: %v", err)
		}
	}
	for _, fetch := range []*shared.TDXFetch{nil, {}} {
		if err := InvalidateTDXFetch(fetch); err == nil {
			t.Fatal("missing invalidation callback accepted")
		}
		if err := AcknowledgeTDXFetch(fetch); err == nil {
			t.Fatal("missing acknowledgement accepted")
		}
	}
}

func TestCommitFetchOrdersCloseBeforeAcknowledgement(t *testing.T) {
	processErr, closeErr, ackErr := errors.New("process"), errors.New("close"), errors.New("ack")
	for _, tc := range []struct {
		process, close, ack error
		want                []string
	}{
		{nil, nil, nil, []string{"process", "close", "ack"}},
		{processErr, nil, nil, []string{"process", "close"}},
		{processErr, closeErr, nil, []string{"process", "close"}},
		{nil, closeErr, nil, []string{"process", "close"}},
		{nil, nil, ackErr, []string{"process", "close", "ack"}},
	} {
		var calls []string
		dec := decoder(`[]`)
		fetch := &shared.TDXFetch{Modified: true, Decoder: dec, Close: func() error { calls = append(calls, "close"); return tc.close }, Ack: func() error { calls = append(calls, "ack"); return tc.ack }}
		err := CommitTDXFetch(fetch, func(got *json.Decoder) error {
			if got != dec {
				t.Fatal("decoder changed")
			}
			calls = append(calls, "process")
			return tc.process
		})
		if !reflect.DeepEqual(calls, tc.want) {
			t.Fatalf("ordering=%v want=%v", calls, tc.want)
		}
		for _, cause := range []error{tc.process, tc.close, tc.ack} {
			if cause != nil && !errors.Is(err, cause) {
				t.Fatalf("lost error %v: %v", cause, err)
			}
		}
		if tc.process == nil && tc.close == nil && tc.ack == nil && err != nil {
			t.Fatal(err)
		}
	}
	for _, fetch := range []*shared.TDXFetch{nil, {}, {Modified: true}, {Modified: true, Decoder: decoder(`[]`)}} {
		if err := CommitTDXFetch(fetch, func(*json.Decoder) error { t.Fatal("invalid fetch processed"); return nil }); err == nil {
			t.Fatal("invalid fetch accepted")
		}
	}
}

type demandSink struct {
	LiveSink
	strings map[string]string
	errors  map[string]error
	writes  []TTLPattern
	execErr error
}

func (s *demandSink) GetString(_ context.Context, key string) (string, error) {
	if err := s.errors[key]; err != nil {
		return "", err
	}
	if value, ok := s.strings[key]; ok {
		return value, nil
	}
	return "", redis.Nil
}
func (s *demandSink) Pipe() LivePipe { return &demandPipe{sink: s} }

type demandPipe struct {
	LivePipe
	sink *demandSink
}

func (p *demandPipe) Set(key string, value any, ttl time.Duration) {
	p.sink.strings[key] = value.(string)
	p.sink.writes = append(p.sink.writes, TTLPattern{key, ttl})
}
func (p *demandPipe) Exec(context.Context) error { return p.sink.execErr }

func TestLiveDemandGate(t *testing.T) {
	t.Setenv("LIVE_DEMAND_GATE", "")
	ctx := context.Background()
	demand := shared.LiveDemandKey("bus_eta", "city")
	cold := shared.LiveColdKey("bus_eta", "city")
	sink := &demandSink{strings: map[string]string{}, errors: map[string]error{}}
	if !LiveDemandGate(ctx, sink, "bus_eta", "city") || LiveDemandGate(ctx, sink, "bus_eta", "city") {
		t.Fatal("cold cadence did not limit polling")
	}
	if !reflect.DeepEqual(sink.writes, []TTLPattern{{cold, LiveColdCadence}}) {
		t.Fatalf("cold marker writes=%v", sink.writes)
	}
	sink.strings[demand] = "1"
	if !LiveDemandGate(ctx, sink, "bus_eta", "city") {
		t.Fatal("active demand was skipped")
	}
	delete(sink.strings, demand)
	sink.errors[demand] = errors.New("demand read failed")
	if !LiveDemandGate(ctx, sink, "bus_eta", "city") {
		t.Fatal("read failure blocked polling")
	}
	delete(sink.errors, demand)
	sink.errors[cold] = errors.New("cold read failed")
	if !LiveDemandGate(ctx, sink, "bus_eta", "city") {
		t.Fatal("cold read failure blocked polling")
	}
	delete(sink.errors, cold)
	delete(sink.strings, cold)
	sink.execErr = errors.New("marker failed")
	if !LiveDemandGate(ctx, sink, "bus_eta", "city") {
		t.Fatal("marker failure blocked polling")
	}
	t.Setenv("LIVE_DEMAND_GATE", "off")
	if !LiveDemandGate(ctx, nil, "bus_eta", "city") {
		t.Fatal("disabled gate read sink")
	}
}

func TestRunLiveFiltersAndIsolatesJobs(t *testing.T) {
	core, logs := observer.New(zap.InfoLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	defer undo()
	var calls []string
	job := func(name string, err error) LiveSpec {
		return LiveSpec{Key: name, Run: func(context.Context, BoundFetch, LiveSink) error { calls = append(calls, name); return err }}
	}
	specs := []LiveSpec{job("first", nil), job("failed", errors.New("fail")), {Key: "panic", Run: func(context.Context, BoundFetch, LiveSink) error { panic("probe") }}, job("last", nil)}
	RunLive(context.Background(), nil, nil, specs, nil)
	if !reflect.DeepEqual(calls, []string{"first", "failed", "last"}) {
		t.Fatal(calls)
	}
	var events []string
	for _, entry := range logs.All() {
		fields := entry.ContextMap()
		events = append(events, fmt.Sprint(fields["job"])+":"+fmt.Sprint(fields["event"]))
	}
	if !reflect.DeepEqual(events, []string{"first:start", "first:complete", "failed:start", "failed:error", "panic:start", "panic:panic", "last:start", "last:complete"}) {
		t.Fatalf("job lifecycle events=%v", events)
	}
	calls = nil
	RunLive(context.Background(), nil, nil, specs, []string{"last", "absent"})
	if !reflect.DeepEqual(calls, []string{"last"}) || len(specs) != 4 || specs[0].Key != "first" {
		t.Fatalf("filtered jobs=%v original=%v", calls, specs)
	}
}

func testRedis(t *testing.T) *redis.Client {
	t.Helper()
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, MaxRetries: -1})
	t.Cleanup(func() { _ = rc.Close() })
	return rc
}

func TestRedisLivePipeAndOwnedTTL(t *testing.T) {
	rc := testRedis(t)
	ctx := context.Background()
	prefix := fmt.Sprintf("quality_shared:%d:%s:", os.Getpid(), t.Name())
	key := prefix + "value"
	owner := prefix + "owner"
	hash := prefix + "hash"
	bike := shared.BikeAvailabilityKey(prefix + "bike")
	observed := shared.BikeAvailabilityObservedAtKey(prefix + "bike")
	t.Cleanup(func() { rc.Del(ctx, key, owner, hash, bike, observed) })
	sink := NewRedisLiveSink(rc)
	pipe := sink.Pipe()
	pipe.Set(key, "value", time.Minute)
	pipe.Set(bike, "bike", time.Minute)
	pipe.Set(observed, "instant", time.Minute)
	pipe.HSet(hash, "field", "data")
	pipe.Expire(hash, time.Minute)
	pipe.Publish(prefix+"channel", "update")
	pipe.ReplaceOwnedKeys(owner, []string{key, bike}, time.Minute)
	if err := pipe.Exec(ctx); err != nil {
		t.Fatal(err)
	}
	if got, err := sink.GetString(ctx, key); err != nil || got != "value" {
		t.Fatalf("string=%q error=%v", got, err)
	}
	if got, err := sink.GetHash(ctx, hash); err != nil || got["field"] != "data" {
		t.Fatalf("hash=%v error=%v", got, err)
	}
	if err := sink.RefreshOwnedTTL(ctx, owner, 42*time.Second); err != nil {
		t.Fatal(err)
	}
	for _, member := range []string{key, bike, observed} {
		if ttl := rc.TTL(ctx, member).Val(); ttl <= 40*time.Second || ttl > 42*time.Second {
			t.Fatalf("TTL %s=%v", member, ttl)
		}
	}
	if ttl := rc.TTL(ctx, owner).Val(); ttl < OwnedKeysTTL-time.Second || ttl > OwnedKeysTTL {
		t.Fatalf("ownership TTL=%v", ttl)
	}
	if err := sink.RefreshTTL(ctx, []TTLPattern{{prefix + "*", 25 * time.Second}, {prefix + "absent:*", time.Minute}}); err != nil {
		t.Fatal(err)
	}
	if ttl := rc.TTL(ctx, key).Val(); ttl < 24*time.Second || ttl > 25*time.Second {
		t.Fatalf("pattern TTL=%v", ttl)
	}
	rc.Del(ctx, key)
	if err := sink.RefreshOwnedTTL(ctx, owner, time.Minute); err == nil || !errMentions(err, "missing live keys") {
		t.Fatalf("missing member error=%v", err)
	}
	if members := rc.SMembers(ctx, owner).Val(); len(members) != 2 {
		t.Fatalf("missing ownership lost=%v", members)
	}
	pipe = sink.Pipe()
	pipe.ReplaceOwnedKeys(owner, nil, time.Minute)
	if err := pipe.Exec(ctx); err != nil {
		t.Fatal(err)
	}
	if rc.Exists(ctx, owner).Val() != 0 {
		t.Fatal("empty replacement retained owner")
	}
	if err := sink.RefreshOwnedTTL(ctx, owner, time.Minute); err != nil {
		t.Fatal(err)
	}
}

func TestRedisLivePipeRejectsUnboundedOrCanceledExecution(t *testing.T) {
	for _, disable := range []func(*redis.Options){func(o *redis.Options) { o.DialTimeout = 0 }, func(o *redis.Options) { o.ReadTimeout = 0 }, func(o *redis.Options) { o.WriteTimeout = 0 }, func(o *redis.Options) { o.PoolTimeout = 0 }} {
		rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", MaxRetries: -1})
		disable(rc.Options())
		if err := NewRedisLiveSink(rc).Pipe().Exec(context.Background()); err == nil || !errMentions(err, "finite Redis") {
			t.Fatalf("unbounded pipeline error=%v", err)
		}
		_ = rc.Close()
	}
	rc := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", DialTimeout: time.Millisecond, ReadTimeout: time.Millisecond, WriteTimeout: time.Millisecond, PoolTimeout: time.Millisecond, MaxRetries: -1})
	defer rc.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := NewRedisLiveSink(rc).Pipe().Exec(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled pipeline error=%v", err)
	}
	sink := NewRedisLiveSink(rc)
	if err := sink.RefreshTTL(context.Background(), []TTLPattern{{"probe:*", time.Minute}}); err == nil {
		t.Fatal("Redis scan failure ignored")
	}
	if err := sink.RefreshOwnedTTL(context.Background(), "probe", time.Minute); err == nil {
		t.Fatal("Redis ownership read failure ignored")
	}
}

func TestInspectOwnedKeysPreservesCommandFailure(t *testing.T) {
	ctx := context.Background()
	command := redis.NewBoolCmd(ctx)
	want := errors.New("expire command failed")
	command.SetErr(want)
	if err := inspectOwnedKeys("owner", []string{"member"}, []*redis.BoolCmd{command}); !errors.Is(err, want) {
		t.Fatalf("expire error=%v", err)
	}
}
