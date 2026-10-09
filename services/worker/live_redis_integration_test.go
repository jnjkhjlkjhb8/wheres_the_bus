package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/redis/go-redis/v9"
)

func TestMrtSpec304RefreshesTTLPerSystem(t *testing.T) {
	// The real mrt spec fetches four systems; with no fixtures every fetch 304s,
	// so its pipeline.BoundFetch must refresh the mrt_live TTL once per system (4×), never
	// writing an arrival.
	src := &fakeLiveSource{fixtures: map[string][]byte{}}
	sink := &captureLiveSink{}
	pipeline.RunLiveSpec(context.Background(), src, sink, specByKey(t, "mrt"))

	if len(sink.sets) != 0 {
		t.Fatalf("expected no SETs on all-304; got %v", setKeys(sink))
	}
	if len(sink.refresh) != 0 {
		t.Fatalf("never-owned systems refreshed keys on 304: %+v", sink.refresh)
	}
}

func TestBike304RefreshesOnlyPartitionOwnedKeys(t *testing.T) {
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"bike_availabilityTaipei": readFixture(t, "tdx_bike_availability.json"),
	}}
	sink := &captureLiveSink{}
	spec := specByKey(t, "bike")
	if err := spec.Run(context.Background(), pipeline.BindFetch(src, sink, spec), sink); err != nil {
		t.Fatalf("initial bike update: %v", err)
	}

	src.fixtures = map[string][]byte{}
	sink.refresh = nil
	if err := spec.Run(context.Background(), pipeline.BindFetch(src, sink, spec), sink); err != nil {
		t.Fatalf("bike 304 update: %v", err)
	}
	want := map[string]bool{
		shared.BikeAvailabilityKey("TPE500101001"): true,
		shared.BikeAvailabilityKey("TPE500101002"): true,
	}
	if len(sink.refresh) != 1 || len(sink.refresh[0]) != len(want) {
		t.Fatalf("bike 304 refreshes = %+v, want owned keys %v", sink.refresh, want)
	}
	for _, refresh := range sink.refresh[0] {
		if !want[refresh.Pattern] || refresh.TTL != pipeline.BikeLiveTTL {
			t.Fatalf("bike 304 refreshed unowned key or wrong TTL: %+v", refresh)
		}
	}
}

func TestFailedFullUpdateDoesNotReplacePartitionOwnership(t *testing.T) {
	wantErr := errors.New("redis exec failed")
	owner := shared.LiveOwnedKeysKey("bike", "Taipei")
	sink := &captureLiveSink{
		owned:   map[string][]string{owner: {"bike_availability:OLD"}},
		execErr: wantErr,
	}
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"bike_availabilityTaipei": readFixture(t, "tdx_bike_availability.json"),
	}}
	spec := specByKey(t, "bike")
	if err := spec.Run(context.Background(), pipeline.BindFetch(src, sink, spec), sink); !errors.Is(err, wantErr) {
		t.Fatalf("bike update error = %v, want %v", err, wantErr)
	}
	if got := sink.owned[owner]; len(got) != 1 || got[0] != "bike_availability:OLD" {
		t.Fatalf("ownership after failed update = %v, want previous ownership", got)
	}
}

func TestRedisOwnedTTLIntegration(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	defer func() { _ = rc.Close() }()
	if err := rc.FlushDB(context.Background()).Err(); err != nil {
		t.Fatalf("flush Redis: %v", err)
	}
	t.Cleanup(func() { _ = rc.FlushDB(context.Background()).Err() })
	owner := shared.LiveOwnedKeysKey("bike", "Taipei")
	owned := shared.BikeAvailabilityKey("TPE-OWNED")
	unowned := shared.BikeAvailabilityKey("NWT-UNOWNED")
	pipe := pipeline.NewRedisLiveSink(rc).Pipe()
	pipe.Set(owned, "owned", 5*time.Second)
	pipe.Set(unowned, "unowned", 5*time.Second)
	pipe.ReplaceOwnedKeys(owner, []string{owned}, pipeline.OwnedKeysTTL)
	if err := pipe.Exec(context.Background()); err != nil {
		t.Fatalf("seed ownership: %v", err)
	}
	if err := (pipeline.NewRedisLiveSink(rc)).RefreshOwnedTTL(context.Background(), owner, pipeline.BikeLiveTTL); err != nil {
		t.Fatalf("refresh owned TTL: %v", err)
	}
	ownedTTL, err := rc.PTTL(context.Background(), owned).Result()
	if err != nil || ownedTTL < time.Minute {
		t.Fatalf("owned TTL = %v, err=%v, want refreshed", ownedTTL, err)
	}
	unownedTTL, err := rc.PTTL(context.Background(), unowned).Result()
	if err != nil || unownedTTL <= 0 || unownedTTL >= 30*time.Second {
		t.Fatalf("unowned TTL = %v, err=%v, want original short TTL", unownedTTL, err)
	}
}

type revalidationLiveSource struct {
	target               string
	body                 []byte
	markerPresent        bool
	invalidationAttempts int
	invalidateErr        error
}

func (s *revalidationLiveSource) Fetch(_ context.Context, _, name string) (*shared.TDXFetch, error) {
	if name != s.target {
		return &shared.TDXFetch{Modified: false, Invalidate: func() error { return nil }}, nil
	}
	if !s.markerPresent {
		return &shared.TDXFetch{
			Modified: true,
			Decoder:  json.NewDecoder(bytes.NewReader(s.body)),
			Close:    func() error { return nil },
			Ack: func() error {
				s.markerPresent = true
				return nil
			},
		}, nil
	}
	return &shared.TDXFetch{Modified: false, Invalidate: func() error {
		s.invalidationAttempts++
		if s.invalidateErr != nil {
			return s.invalidateErr
		}
		s.markerPresent = false
		return nil
	}}, nil
}

func TestRedisMissingOwnedMemberRetriesInvalidationThenReplacesOwner(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	defer func() { _ = rc.Close() }()
	if err := rc.FlushDB(context.Background()).Err(); err != nil {
		t.Fatalf("flush Redis: %v", err)
	}
	t.Cleanup(func() { _ = rc.FlushDB(context.Background()).Err() })
	owner := shared.LiveOwnedKeysKey("bike", "Taipei")
	missing := shared.BikeAvailabilityKey("EXPIRED")
	if err := rc.SAdd(context.Background(), owner, missing).Err(); err != nil {
		t.Fatalf("seed stale owner: %v", err)
	}
	if err := rc.Expire(context.Background(), owner, 5*time.Minute).Err(); err != nil {
		t.Fatalf("expire owner: %v", err)
	}
	invalidateErr := errors.New("invalidate marker failed")
	src := &revalidationLiveSource{
		target:        "bike_availabilityTaipei",
		body:          readFixture(t, "tdx_bike_availability.json"),
		markerPresent: true,
		invalidateErr: invalidateErr,
	}
	spec := specByKey(t, "bike")
	fetch := pipeline.BindFetch(src, pipeline.NewRedisLiveSink(rc), spec)

	for attempt := 1; attempt <= 2; attempt++ {
		if _, err := fetch(context.Background(), "/bike", src.target); !errors.Is(err, invalidateErr) {
			t.Fatalf("attempt %d stale ownership error = %v, want joined invalidation error", attempt, err)
		}
		if !src.markerPresent {
			t.Fatalf("attempt %d cleared marker despite failed invalidation", attempt)
		}
		if exists, err := rc.Exists(context.Background(), owner).Result(); err != nil || exists != 1 {
			t.Fatalf("attempt %d stale owner exists=%d err=%v, want retained for retry", attempt, exists, err)
		}
	}
	if src.invalidationAttempts != 2 {
		t.Fatalf("invalidation attempts = %d, want 2", src.invalidationAttempts)
	}
	ownerTTL, err := rc.PTTL(context.Background(), owner).Result()
	if err != nil || ownerTTL <= 0 || ownerTTL >= 10*time.Minute {
		t.Fatalf("stale owner TTL = %v err=%v, want retained without 24h renewal", ownerTTL, err)
	}

	src.invalidateErr = nil
	if _, err := fetch(context.Background(), "/bike", src.target); err == nil {
		t.Fatal("successful marker invalidation hid stale ownership error")
	}
	if src.markerPresent {
		t.Fatal("successful invalidation left marker present")
	}
	if exists, err := rc.Exists(context.Background(), owner).Result(); err != nil || exists != 1 {
		t.Fatalf("stale owner after successful invalidation exists=%d err=%v, want retained until full write", exists, err)
	}

	if err := spec.Run(context.Background(), pipeline.BindFetch(src, pipeline.NewRedisLiveSink(rc), spec), pipeline.NewRedisLiveSink(rc)); err != nil {
		t.Fatalf("full bike refresh after invalidation: %v", err)
	}
	wantMembers := map[string]bool{
		shared.BikeAvailabilityKey("TPE500101001"): true,
		shared.BikeAvailabilityKey("TPE500101002"): true,
	}
	members, err := rc.SMembers(context.Background(), owner).Result()
	if err != nil {
		t.Fatalf("read replacement owner: %v", err)
	}
	if len(members) != len(wantMembers) {
		t.Fatalf("replacement owner members = %v, want %v", members, wantMembers)
	}
	for _, member := range members {
		if !wantMembers[member] {
			t.Fatalf("replacement owner retained stale member %q", member)
		}
	}
}

func TestRedisCanceledTHSRExecDoesNotAcknowledge(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR not set")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr})
	defer func() { _ = rc.Close() }()
	if err := rc.FlushDB(context.Background()).Err(); err != nil {
		t.Fatalf("flush Redis: %v", err)
	}
	if err := rc.Do(context.Background(), "CLIENT", "PAUSE", 250, "WRITE").Err(); err != nil {
		t.Fatalf("pause Redis writes: %v", err)
	}
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"thsr_availableseats": readFixture(t, "tdx_thsr_availableseats.json"),
	}}
	spec := specByKey(t, "thsr_seats")
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	started := time.Now()
	err := spec.Run(ctx, pipeline.BindFetch(src, pipeline.NewRedisLiveSink(rc), spec), pipeline.NewRedisLiveSink(rc))
	elapsed := time.Since(started)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("THSR Exec error = %v, want context deadline exceeded", err)
	}
	if elapsed < 150*time.Millisecond {
		t.Fatalf("canceled THSR returned after %v while paused transaction was still pending", elapsed)
	}
	if len(src.closed) != 1 {
		t.Fatalf("THSR response closes = %d, want decode reached before cancellation", len(src.closed))
	}
	if len(src.acked) != 0 {
		t.Fatalf("canceled Redis Exec acknowledged marker: %v", src.acked)
	}
	key := shared.ThsrSeatsKey(time.Now().In(pipeline.Taipei).Format(time.DateOnly), "0801")
	const newer = "newer same-runner snapshot"
	if err := rc.Set(context.Background(), key, newer, time.Minute).Err(); err != nil {
		t.Fatalf("write newer snapshot after canceled call returned: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	got, err := rc.Get(context.Background(), key).Result()
	if err != nil {
		t.Fatalf("read final snapshot: %v", err)
	}
	if got != newer {
		t.Fatalf("final snapshot = %q, want newer write; canceled transaction landed late", got)
	}
}

func TestRedisLivePipelineRejectsUnboundedSocketWait(t *testing.T) {
	rc := redis.NewClient(&redis.Options{
		Addr:        "127.0.0.1:1",
		ReadTimeout: -1,
	})
	defer func() { _ = rc.Close() }()
	pipe := pipeline.NewRedisLiveSink(rc).Pipe()
	pipe.Set("unreachable", "value", time.Minute)
	if err := pipe.Exec(context.Background()); err == nil || !errMentions(err, "finite Redis read timeout") {
		t.Fatalf("Exec error = %v, want finite-timeout guard", err)
	}
}
