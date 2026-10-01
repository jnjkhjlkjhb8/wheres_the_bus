package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/mrt"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/redis/go-redis/v9"
	"google.golang.org/protobuf/proto"
)

type fakeLiveSource struct {
	fixtures      map[string][]byte // Key: fetch name → raw TDX JSON array
	calls         []string
	acked         []string
	closed        []string
	invalidated   []string
	ackErr        error
	ackErrors     map[string]error
	closeErr      error
	invalidateErr error
}

func (s *fakeLiveSource) Fetch(_ context.Context, _, name string) (*shared.TDXFetch, error) {
	s.calls = append(s.calls, name)
	body, ok := s.fixtures[name]
	if !ok {
		return &shared.TDXFetch{
			Modified: false,
			Invalidate: func() error {
				s.invalidated = append(s.invalidated, name)
				return s.invalidateErr
			},
		}, nil
	}
	return &shared.TDXFetch{
		Decoder:  json.NewDecoder(bytes.NewReader(body)),
		Modified: true,
		Ack: func() error {
			s.acked = append(s.acked, name)
			if err := s.ackErrors[name]; err != nil {
				return err
			}
			return s.ackErr
		},
		Close: func() error {
			s.closed = append(s.closed, name)
			return s.closeErr
		},
		Invalidate: func() error {
			s.invalidated = append(s.invalidated, name)
			return s.invalidateErr
		},
	}, nil
}

// setWrite records one pipelined SET.
type setWrite struct {
	key   string
	value []byte
	ttl   time.Duration
}

// publishWrite records one pipelined PUBLISH.
type publishWrite struct {
	channel string
	value   []byte
}

// hsetWrite records one pipelined HSET.
type hsetWrite struct {
	key   string
	field string
	value string
}

// expireWrite records one pipelined EXPIRE.
type expireWrite struct {
	key string
	ttl time.Duration
}

type captureLiveSink struct {
	mu       sync.Mutex
	sets     []setWrite
	publishs []publishWrite
	hsets    []hsetWrite
	expires  []expireWrite
	refresh  [][]pipeline.TTLPattern
	// strings and hashes seed the read seam so a test can drive the bus weather
	// read and the tra delay-hash merge without a live Redis.
	strings    map[string]string
	hashes     map[string]map[string]string
	owned      map[string][]string
	execErr    error
	execHook   func() error
	refreshErr error
	contexts   []context.Context
}

func (s *captureLiveSink) Pipe() pipeline.LivePipe {
	return &capturePipe{sink: s}
}

func (s *captureLiveSink) RefreshTTL(_ context.Context, patterns []pipeline.TTLPattern) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refresh = append(s.refresh, patterns)
	return s.refreshErr
}

func (s *captureLiveSink) RefreshOwnedTTL(ctx context.Context, key string, ttl time.Duration) error {
	s.mu.Lock()
	members := append([]string(nil), s.owned[key]...)
	s.mu.Unlock()
	if len(members) == 0 {
		return nil
	}
	patterns := make([]pipeline.TTLPattern, 0, len(members))
	for _, member := range members {
		patterns = append(patterns, pipeline.TTLPattern{Pattern: member, TTL: ttl})
	}
	return s.RefreshTTL(ctx, patterns)
}

func (s *captureLiveSink) GetString(_ context.Context, key string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if v, ok := s.strings[key]; ok {
		return v, nil
	}
	return "", redis.Nil
}

func (s *captureLiveSink) GetHash(_ context.Context, key string) (map[string]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if v, ok := s.hashes[key]; ok {
		return v, nil
	}
	return map[string]string{}, nil
}

// setFor returns the captured SET for key, or nil. Called only after the run
// under test has finished, but locked anyway so it stays safe if that ever
// changes.
func (s *captureLiveSink) setFor(key string) *setWrite {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.sets {
		if s.sets[i].key == key {
			w := s.sets[i]
			return &w
		}
	}
	return nil
}

type capturePipe struct {
	sink                *captureLiveSink
	pendingOwnedKey     string
	pendingOwnedMembers []string
}

func (p *capturePipe) Set(key string, value any, ttl time.Duration) {
	p.sink.mu.Lock()
	defer p.sink.mu.Unlock()
	p.sink.sets = append(p.sink.sets, setWrite{key: key, value: toBytes(value), ttl: ttl})
	// Make the write visible to getString, as Redis would: liveDemandGate reads
	// back a marker it wrote on an earlier tick, so a write-only fake would let
	// it fetch every tick and the gate would test as working while doing nothing.
	if p.sink.strings == nil {
		p.sink.strings = map[string]string{}
	}
	p.sink.strings[key] = string(toBytes(value))
}

func (p *capturePipe) Publish(channel string, value any) {
	p.sink.mu.Lock()
	defer p.sink.mu.Unlock()
	p.sink.publishs = append(p.sink.publishs, publishWrite{channel: channel, value: toBytes(value)})
}

func (p *capturePipe) HSet(key, field string, value any) {
	p.sink.mu.Lock()
	defer p.sink.mu.Unlock()
	p.sink.hsets = append(p.sink.hsets, hsetWrite{key: key, field: field, value: toString(value)})
}

func (p *capturePipe) Expire(key string, ttl time.Duration) {
	p.sink.mu.Lock()
	defer p.sink.mu.Unlock()
	p.sink.expires = append(p.sink.expires, expireWrite{key: key, ttl: ttl})
}

func (p *capturePipe) ReplaceOwnedKeys(key string, members []string, _ time.Duration) {
	// Buffered on the pipe itself, not the shared sink — safe unlocked, and
	// applied to the sink under lock in Exec below.
	p.pendingOwnedKey = key
	p.pendingOwnedMembers = append([]string(nil), members...)
}

func (p *capturePipe) Exec(ctx context.Context) error {
	p.sink.mu.Lock()
	defer p.sink.mu.Unlock()
	// Recorded here rather than at pipeline construction: Exec is the call that
	// carries the context to Redis, so this is what the job must be propagating.
	p.sink.contexts = append(p.sink.contexts, ctx)
	if p.sink.execHook != nil {
		if err := p.sink.execHook(); err != nil {
			return err
		}
	}
	if p.sink.execErr != nil {
		return p.sink.execErr
	}
	if p.pendingOwnedKey != "" {
		if p.sink.owned == nil {
			p.sink.owned = make(map[string][]string)
		}
		p.sink.owned[p.pendingOwnedKey] = append([]string(nil), p.pendingOwnedMembers...)
	}
	return nil
}

// toBytes normalizes the []byte / string values the jobs marshal into SET/PUBLISH.
func toBytes(v any) []byte {
	switch t := v.(type) {
	case []byte:
		return t
	case string:
		return []byte(t)
	default:
		return nil
	}
}

// toString normalizes the HSET value (jobs pass a uint16 delay).
func toString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	// The value is a numeric delay; format it the way Redis would store it.
	b, _ := json.Marshal(v)
	return string(b)
}

// setKeys lists captured SET keys for failure messages.
func setKeys(s *captureLiveSink) []string {
	out := make([]string, 0, len(s.sets))
	for _, w := range s.sets {
		out = append(out, w.key)
	}
	return out
}

// readFixture loads a committed TDX fixture from testdata/.
func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return b
}

// specByKey returns the registered pipeline.LiveSpec with the given key.
func specByKey(t *testing.T, key string) pipeline.LiveSpec {
	t.Helper()
	for _, s := range liveRegistry(nil, nil) {
		if s.Key == key {
			return s
		}
	}
	t.Fatalf("no live spec with key %q", key)
	return pipeline.LiveSpec{}
}

// _trtcTestNames is the station-name fixture the TRTC live tests resolve
// against (mrt_station is not available in unit tests).
var _trtcTestNames = map[string][]string{
	"台北車站":  {"BL12", "R10"},
	"南港展覽館": {"BL23", "BR24"},
	"頂埔":    {"BL01"},
}

// _trtcTestTracks: two arrivals at BL12 toward opposite BL terminals; train 215
// has a congestion reading, train 222 does not.

func TestTraSpecCachesDelays(t *testing.T) {
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"tra_delay": readFixture(t, "tdx_tra_delay.json"),
	}}
	sink := &captureLiveSink{
		hashes: map[string]map[string]string{
			shared.TraDelayHashKey: {"1234": "9"},
		},
	}
	pipeline.RunLiveSpec(context.Background(), src, sink, specByKey(t, "tra"))

	// Delay hash: train 1234 delayed 5 minutes (from the delay feed, via the sink).
	var hset *hsetWrite
	for i := range sink.hsets {
		if sink.hsets[i].key == shared.TraDelayHashKey && sink.hsets[i].field == "1234" {
			hset = &sink.hsets[i]
		}
	}
	if hset == nil || hset.value != "5" {
		t.Fatalf("expected HSET %s 1234 = 5; got %+v", shared.TraDelayHashKey, sink.hsets)
	}
	// All-delay snapshot cached with the 3m TTL and published for streaming.
	if sw := sink.setFor(shared.TraDelayAllKey); sw == nil || sw.ttl != pipeline.TraLiveTTL {
		t.Fatalf("expected SET %s ttl=%v; got %+v", shared.TraDelayAllKey, pipeline.TraLiveTTL, sw)
	}
	var pub *publishWrite
	for i := range sink.publishs {
		if sink.publishs[i].channel == shared.TraDelayAllKey {
			pub = &sink.publishs[i]
		}
	}
	if pub == nil {
		t.Fatalf("expected PUBLISH to %s; got %+v", shared.TraDelayAllKey, sink.publishs)
	}
	trainChannel := shared.TraDelayTrainChannel("1234")
	var trainPublish *publishWrite
	for i := range sink.publishs {
		if sink.publishs[i].channel == trainChannel {
			trainPublish = &sink.publishs[i]
		}
	}
	if trainPublish == nil {
		t.Fatalf("expected per-train PUBLISH to %s; got %+v", trainChannel, sink.publishs)
	}
	var trainSnapshot models.TraDelays
	if err := proto.Unmarshal(trainPublish.value, &trainSnapshot); err != nil {
		t.Fatalf("unmarshal per-train delay: %v", err)
	}
	if len(trainSnapshot.Delay) != 1 || trainSnapshot.Delay["1234"] != 5 {
		t.Fatalf("per-train snapshot = %+v", trainSnapshot.Delay)
	}
	// No liveboard writes remain.
	for _, k := range setKeys(sink) {
		if strings.HasPrefix(k, "tra:liveboard") {
			t.Fatalf("unexpected liveboard write %s", k)
		}
	}
}
func TestBikeSpecWritesAvailability(t *testing.T) {
	// The bike spec must write one BikeEta per station under its availability key
	// with the 2-minute TTL and the decoded rentable/returnable counts. db is nil
	// so history sampling is skipped (the realtime path runs without a database).
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"bike_availabilityTaipei": readFixture(t, "tdx_bike_availability.json"),
	}}
	sink := &captureLiveSink{}
	pipeline.RunLiveSpec(context.Background(), src, sink, specByKey(t, "bike"))

	key := shared.BikeAvailabilityKey("TPE500101001")
	sw := sink.setFor(key)
	if sw == nil {
		t.Fatalf("expected SET for %s; got %v", key, setKeys(sink))
	}
	if sw.ttl != pipeline.BikeLiveTTL {
		t.Fatalf("bike SET ttl = %v, want %v", sw.ttl, pipeline.BikeLiveTTL)
	}
	var got models.BikeEta
	if err := proto.Unmarshal(sw.value, &got); err != nil {
		t.Fatalf("unmarshal BikeEta: %v", err)
	}
	if got.StationUID != "TPE500101001" || got.GeneralBikes != 5 || got.ElectricBikes != 3 {
		t.Fatalf("BikeEta = %+v", &got)
	}
	if got.AvailableReturnBikes != 12 {
		t.Fatalf("AvailableReturnBikes = %d, want 12", got.AvailableReturnBikes)
	}
}

func TestThsrSeatsSpecWritesSeats(t *testing.T) {
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"thsr_availableseats": readFixture(t, "tdx_thsr_availableseats.json"),
	}}
	sink := &captureLiveSink{}
	pipeline.RunLiveSpec(context.Background(), src, sink, specByKey(t, "thsr_seats"))

	date := time.Now().In(pipeline.Taipei).Format(time.DateOnly)

	// Train 0801 carries both fixture segments, aggregated into one snapshot.
	sw := sink.setFor(shared.ThsrSeatsKey(date, "0801"))
	if sw == nil {
		t.Fatalf("expected SET for train 0801; got keys %v", setKeys(sink))
	}
	if sw.ttl != pipeline.ThsrSeatsLiveTTL {
		t.Fatalf("thsr seats SET ttl = %v, want %v", sw.ttl, pipeline.ThsrSeatsLiveTTL)
	}
	var got models.ThsrAvailableSeats
	if err := proto.Unmarshal(sw.value, &got); err != nil {
		t.Fatalf("unmarshal ThsrAvailableSeats: %v", err)
	}
	if len(got.Segments) != 2 {
		t.Fatalf("train 0801 segments = %d, want 2", len(got.Segments))
	}
	if got.Segments[0].OriginStationId != "0990" || got.Segments[0].StandardSeatStatus != "O" {
		t.Fatalf("segment[0] = %+v", got.Segments[0])
	}
	if got.Segments[1].DestinationStationId != "1070" || got.Segments[1].StandardSeatStatus != "L" {
		t.Fatalf("segment[1] = %+v", got.Segments[1])
	}

	// Train 0803 has a single segment and is also written.
	if sw := sink.setFor(shared.ThsrSeatsKey(date, "0803")); sw == nil {
		t.Fatalf("expected SET for train 0803; got keys %v", setKeys(sink))
	}

	// Both trains publish to the per-date channel.
	channel := shared.ThsrSeatsPattern(date)
	pubCount := 0
	for _, p := range sink.publishs {
		if p.channel == channel {
			pubCount++
		}
	}
	if pubCount != 2 {
		t.Fatalf("publishes to %s = %d, want 2", channel, pubCount)
	}
}

func TestThsrSeatsSpec304RefreshesTTL(t *testing.T) {
	// With no fixture the seat fetch 304s, so the spec must re-arm today's seat-key
	// TTL once via pipeline.BoundFetch and write nothing.
	src := &fakeLiveSource{fixtures: map[string][]byte{}}
	sink := &captureLiveSink{}
	pipeline.RunLiveSpec(context.Background(), src, sink, specByKey(t, "thsr_seats"))

	if len(sink.sets) != 0 {
		t.Fatalf("expected no SETs on a 304; got %v", setKeys(sink))
	}
	if len(sink.refresh) != 1 {
		t.Fatalf("refreshTTL calls = %d, want 1", len(sink.refresh))
	}
	date := time.Now().In(pipeline.Taipei).Format(time.DateOnly)
	got := sink.refresh[0]
	if len(got) != 1 || got[0].Pattern != shared.ThsrSeatsPattern(date) || got[0].TTL != pipeline.ThsrSeatsLiveTTL {
		t.Fatalf("refresh patterns = %+v", got)
	}
}

func TestBoundFetch304RefreshesTTL(t *testing.T) {
	// When TDX answers 304, pipeline.BoundFetch must re-arm the spec's ttlPatterns through
	// the sink before returning modified=false — the generalized 304→TTL rule for
	// jobs that previously just skipped (mrt/tra/bike).
	src := &fakeLiveSource{fixtures: map[string][]byte{}} // every name 304s
	sink := &captureLiveSink{}
	spec := pipeline.LiveSpec{
		Key: "probe",
		TTLPatterns: func(string) []pipeline.TTLPattern {
			return []pipeline.TTLPattern{{Pattern: "mrt_live:*", TTL: pipeline.MrtLiveTTL}}
		},
	}
	fetch := pipeline.BindFetch(src, sink, spec)
	result, err := fetch(context.Background(), "/x", "unseeded")
	if err != nil {
		t.Fatalf("fetch error: %v", err)
	}
	if result.Modified {
		t.Fatal("expected modified=false for a 304")
	}
	if len(sink.refresh) != 1 {
		t.Fatalf("refreshTTL calls = %d, want 1", len(sink.refresh))
	}
	got := sink.refresh[0]
	if len(got) != 1 || got[0].Pattern != "mrt_live:*" || got[0].TTL != pipeline.MrtLiveTTL {
		t.Fatalf("refresh patterns = %+v", got)
	}
}

func TestBoundFetchReturnsTTLRefreshError(t *testing.T) {
	wantErr := errors.New("expire failed")
	src := &fakeLiveSource{fixtures: map[string][]byte{}}
	sink := &captureLiveSink{refreshErr: wantErr}
	spec := pipeline.LiveSpec{
		Key: "probe",
		TTLPatterns: func(string) []pipeline.TTLPattern {
			return []pipeline.TTLPattern{{Pattern: "probe:*", TTL: time.Minute}}
		},
	}
	_, err := pipeline.BindFetch(src, sink, spec)(context.Background(), "/probe", "probe")
	if !errors.Is(err, wantErr) {
		t.Fatalf("304 refresh error = %v, want %v", err, wantErr)
	}
}

func TestFailedDecodeOrPublishLeavesMarkerUnchanged(t *testing.T) {
	t.Run("decode", func(t *testing.T) {
		src := &fakeLiveSource{fixtures: map[string][]byte{
			"thsr_availableseats": []byte(`[{"TrainDate":`),
		}}
		sink := &captureLiveSink{}
		spec := specByKey(t, "thsr_seats")

		err := spec.Run(context.Background(), pipeline.BindFetch(src, sink, spec), sink)
		if err == nil {
			t.Fatal("malformed TDX payload returned nil error")
		}
		if len(src.acked) != 0 {
			t.Fatalf("malformed payload acked marker: %v", src.acked)
		}
		if len(src.closed) != 1 {
			t.Fatalf("malformed payload closes = %d, want 1", len(src.closed))
		}
	})

	t.Run("publish", func(t *testing.T) {
		publishErr := errors.New("redis publish failed")
		src := &fakeLiveSource{fixtures: map[string][]byte{
			"thsr_availableseats": readFixture(t, "tdx_thsr_availableseats.json"),
		}}
		sink := &captureLiveSink{execErr: publishErr}
		spec := specByKey(t, "thsr_seats")

		err := spec.Run(context.Background(), pipeline.BindFetch(src, sink, spec), sink)
		if !errors.Is(err, publishErr) {
			t.Fatalf("publish error = %v, want %v", err, publishErr)
		}
		if len(src.acked) != 0 {
			t.Fatalf("failed publish acked marker: %v", src.acked)
		}
		if len(src.closed) != 1 {
			t.Fatalf("failed publish closes = %d, want 1", len(src.closed))
		}
	})
}

func TestRealtimePipelineFailureDoesNotAcknowledge(t *testing.T) {
	wantErr := errors.New("redis pipeline failed")
	tests := []struct {
		name    string
		specKey string
		fixture string
		body    []byte
	}{
		{name: "bike", specKey: "bike", fixture: "bike_availabilityTaipei", body: readFixture(t, "tdx_bike_availability.json")},
		{name: "tra", specKey: "tra", fixture: "tra_delay", body: readFixture(t, "tdx_tra_delay.json")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := &fakeLiveSource{fixtures: map[string][]byte{tt.fixture: tt.body}}
			sink := &captureLiveSink{execErr: wantErr}
			spec := specByKey(t, tt.specKey)
			err := spec.Run(context.Background(), pipeline.BindFetch(src, sink, spec), sink)
			if !errors.Is(err, wantErr) {
				t.Fatalf("pipeline error = %v, want wrapped %v", err, wantErr)
			}
			if len(src.acked) != 0 {
				t.Fatalf("pipeline failure acknowledged marker: %v", src.acked)
			}
		})
	}
}

func TestRealtimePipelineReceivesJobContext(t *testing.T) {
	type contextKey string
	ctx := context.WithValue(context.Background(), contextKey("job"), "bike")
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"bike_availabilityTaipei": readFixture(t, "tdx_bike_availability.json"),
	}}
	sink := &captureLiveSink{}
	spec := specByKey(t, "bike")
	if err := spec.Run(ctx, pipeline.BindFetch(src, sink, spec), sink); err != nil {
		t.Fatalf("bike run: %v", err)
	}
	if len(sink.contexts) == 0 || sink.contexts[0] != ctx {
		t.Fatalf("pipeline contexts = %v, want job context", sink.contexts)
	}
}

func TestLiveConsumerReturnsAckAndCloseErrors(t *testing.T) {
	tests := []struct {
		name     string
		ackErr   error
		closeErr error
		wantAcks int
	}{
		{name: "ack", ackErr: errors.New("marker write failed"), wantAcks: 1},
		{name: "close", closeErr: errors.New("response close failed"), wantAcks: 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := &fakeLiveSource{
				fixtures: map[string][]byte{
					"thsr_availableseats": readFixture(t, "tdx_thsr_availableseats.json"),
				},
				ackErr:   tt.ackErr,
				closeErr: tt.closeErr,
			}
			sink := &captureLiveSink{}
			spec := specByKey(t, "thsr_seats")

			err := spec.Run(context.Background(), pipeline.BindFetch(src, sink, spec), sink)
			want := tt.ackErr
			if want == nil {
				want = tt.closeErr
			}
			if !errors.Is(err, want) {
				t.Fatalf("consumer error = %v, want %v", err, want)
			}
			if len(src.acked) != tt.wantAcks || len(src.closed) != 1 {
				t.Fatalf("acked/closed = %v/%v, want %d/1", src.acked, src.closed, tt.wantAcks)
			}
		})
	}
}

func TestCommitTDXFetchClosesBeforeAck(t *testing.T) {
	closeErr := errors.New("close failed")
	acked := false
	fetch := &shared.TDXFetch{
		Decoder:  json.NewDecoder(strings.NewReader(`[]`)),
		Modified: true,
		Ack: func() error {
			acked = true
			return nil
		},
		Close: func() error { return closeErr },
	}
	err := pipeline.CommitTDXFetch(fetch, func(dec *json.Decoder) error {
		return pipeline.DecodeLiveItems(dec, func(struct{}) error { return nil })
	})
	if !errors.Is(err, closeErr) {
		t.Fatalf("commit error = %v, want %v", err, closeErr)
	}
	if acked {
		t.Fatal("fetch was acknowledged despite close failure")
	}
}

func TestCommitTDXFetchRequiresCloseBeforeAck(t *testing.T) {
	acked := false
	fetch := &shared.TDXFetch{
		Decoder:  json.NewDecoder(strings.NewReader(`[]`)),
		Modified: true,
		Ack: func() error {
			acked = true
			return nil
		},
	}
	err := pipeline.CommitTDXFetch(fetch, func(dec *json.Decoder) error {
		return pipeline.DecodeLiveItems(dec, func(struct{}) error { return nil })
	})
	if err == nil {
		t.Fatal("commit without Close returned nil error")
	}
	if acked {
		t.Fatal("fetch without Close was acknowledged")
	}
}

func TestCorruptGzipChecksumDoesNotAck(t *testing.T) {
	var compressed bytes.Buffer
	zw := gzip.NewWriter(&compressed)
	_, _ = zw.Write([]byte(`[]`))
	_ = zw.Close()
	data := compressed.Bytes()
	data = data[:len(data)-4]
	zr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("gzip.NewReader: %v", err)
	}
	acked := false
	fetch := &shared.TDXFetch{
		Decoder:  json.NewDecoder(zr),
		Modified: true,
		Ack: func() error {
			acked = true
			return nil
		},
		Close: zr.Close,
	}
	err = pipeline.CommitTDXFetch(fetch, func(dec *json.Decoder) error {
		return pipeline.DecodeLiveItems(dec, func(struct{}) error { return nil })
	})
	if err == nil {
		t.Fatal("corrupt gzip checksum returned nil error")
	}
	if acked {
		t.Fatal("corrupt gzip response was acknowledged")
	}
}

// TRTC fixtures for the cross-domain cancel-during-Exec invariant. The mrt
// package keeps its own copies for the publish path's own tests.
var _trtcTestTracks = []mrt.TrtcTrack{
	{TrainNumber: "215", StationName: "台北車站", DestinationName: "南港展覽館站", CountDown: "02:00", NowDateTime: "2026-07-22 15:09:55"},
	{TrainNumber: "222", StationName: "台北車站", DestinationName: "頂埔站", CountDown: "01:10", NowDateTime: "2026-07-22 15:09:55"},
}

func TestAllRealtimeWritersCancelDuringExecWithoutAck(t *testing.T) {
	tests := []struct {
		name     string
		fixtures map[string][]byte
		run      func(context.Context, *fakeLiveSource, *captureLiveSink) error
	}{
		{name: "bike", fixtures: map[string][]byte{"bike_availabilityTaipei": readFixture(t, "tdx_bike_availability.json")}, run: func(ctx context.Context, src *fakeLiveSource, sink *captureLiveSink) error {
			spec := specByKey(t, "bike")
			return spec.Run(ctx, pipeline.BindFetch(src, sink, spec), sink)
		}},
		// mrt is TRTC-sourced now (no TDX fetch/marker); it keeps the same
		// cancel-during-Exec invariant via trtcPublish, driven fixture-direct.
		{name: "mrt", fixtures: map[string][]byte{}, run: func(ctx context.Context, src *fakeLiveSource, sink *captureLiveSink) error {
			return mrt.TrtcPublish(ctx, sink, _trtcTestNames, nil, time.Now(), _trtcTestTracks, nil, nil)
		}},
		{name: "tra", fixtures: map[string][]byte{"tra_delay": readFixture(t, "tdx_tra_delay.json")}, run: func(ctx context.Context, src *fakeLiveSource, sink *captureLiveSink) error {
			spec := specByKey(t, "tra")
			return spec.Run(ctx, pipeline.BindFetch(src, sink, spec), sink)
		}},
		{name: "thsr", fixtures: map[string][]byte{"thsr_availableseats": readFixture(t, "tdx_thsr_availableseats.json")}, run: func(ctx context.Context, src *fakeLiveSource, sink *captureLiveSink) error {
			spec := specByKey(t, "thsr_seats")
			return spec.Run(ctx, pipeline.BindFetch(src, sink, spec), sink)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			src := &fakeLiveSource{fixtures: test.fixtures}
			execStarted := false
			sink := &captureLiveSink{execHook: func() error {
				execStarted = true
				cancel()
				<-ctx.Done()
				return ctx.Err()
			}}
			err := test.run(ctx, src, sink)
			if !execStarted {
				t.Fatal("test did not cancel during Exec")
			}
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("writer error = %v, want context canceled", err)
			}
			if len(src.acked) != 0 {
				t.Fatalf("canceled Exec acknowledged TDX marker: %v", src.acked)
			}
			if len(sink.contexts) == 0 || sink.contexts[0] != ctx {
				t.Fatalf("pipeline contexts = %v, want job context", sink.contexts)
			}
		})
	}
}
