package mrt

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/redis/go-redis/v9"
	"google.golang.org/protobuf/proto"
)

var _trtcTestTracks = []TrtcTrack{
	{TrainNumber: "215", StationName: "台北車站", DestinationName: "南港展覽館站", CountDown: "02:00", NowDateTime: "2026-07-22 15:09:55"},
	{TrainNumber: "222", StationName: "台北車站", DestinationName: "頂埔站", CountDown: "01:10", NowDateTime: "2026-07-22 15:09:55"},
}

func TestTrtcPublishWritesArrivals(t *testing.T) {
	// The TRTC publish core must write one per-(station,line,dest) key and
	// publish per-station updates, with the countdown parsed into EstimateTime
	// and train 215's congestion paired on (congestion pairing, CONTEXT.md).
	sink := &captureLiveSink{}
	exRows := []trtcWeightEx{{TrainNumber: "215", CN1: "163/164", StationID: "BL10",
		Cart1L: "1", Cart2L: "2", Cart3L: "2", Cart4L: "2", Cart5L: "2", Cart6L: "1"}}
	if err := TrtcPublish(context.Background(), sink, _trtcTestNames, nil, time.Now(), _trtcTestTracks, exRows, nil); err != nil {
		t.Fatalf("trtcPublish: %v", err)
	}

	key := shared.MrtLiveKey("TRTC", "BL12", "BL", "BL23")
	sw := sink.setFor(key)
	if sw == nil {
		t.Fatalf("expected SET for %s; got keys %v", key, setKeys(sink))
	}
	if sw.ttl != pipeline.MrtLiveTTL {
		t.Fatalf("mrt SET ttl = %v, want %v", sw.ttl, pipeline.MrtLiveTTL)
	}
	var got models.MrtLive
	if err := proto.Unmarshal(sw.value, &got); err != nil {
		t.Fatalf("unmarshal MrtLive: %v", err)
	}
	if got.System != "TRTC" || got.StationID != "BL12" || got.LineID != "BL" {
		t.Fatalf("MrtLive identity = %+v", &got)
	}
	if got.EstimateTime != 120 || got.DestinationStationName != "南港展覽館" || got.CountDown != "02:00" {
		t.Fatalf("MrtLive payload = %+v", &got)
	}
	if got.Weight == nil || got.Weight.Cart2L != "2" || got.CN1 != "163/164" {
		t.Fatalf("MrtLive congestion = %+v", &got)
	}
	// The number-less pairing must not leak: train 222 has no congestion.
	other := sink.setFor(shared.MrtLiveKey("TRTC", "BL12", "BL", "BL01"))
	if other == nil {
		t.Fatalf("expected SET for opposite destination; got keys %v", setKeys(sink))
	}
	var plain models.MrtLive
	if err := proto.Unmarshal(other.value, &plain); err != nil {
		t.Fatalf("unmarshal MrtLive: %v", err)
	}
	if plain.Weight != nil {
		t.Fatalf("unpaired arrival carries congestion: %+v", &plain)
	}
	// Both rows share station BL12, so both publish the station channel.
	ch := shared.MrtLiveChannel("TRTC", "BL12")
	pubCount := 0
	for _, p := range sink.publishs {
		if p.channel == ch {
			pubCount++
		}
	}
	if pubCount != 2 {
		t.Fatalf("publishes to %s = %d, want 2", ch, pubCount)
	}
}

func TestTrtcOppositeDestinationsUseDistinctRedisKeys(t *testing.T) {
	sink := &captureLiveSink{}
	if err := TrtcPublish(context.Background(), sink, _trtcTestNames, nil, time.Now(), _trtcTestTracks, nil, nil); err != nil {
		t.Fatalf("trtcPublish: %v", err)
	}
	keys := map[string]struct{}{}
	for _, write := range sink.sets {
		if strings.HasPrefix(write.key, shared.MrtLiveChannel("TRTC", "BL12")+":") {
			keys[write.key] = struct{}{}
		}
	}
	if len(keys) != 2 {
		t.Fatalf("distinct Redis keys for opposite BL destinations = %d, want 2; writes=%v", len(keys), setKeys(sink))
	}
}

// The TRTC job has no TDX marker to (not) acknowledge, but the pipeline
// invariant still holds: a failed Exec must surface as the job error.
func TestTrtcPublishExecFailure(t *testing.T) {
	wantErr := errors.New("redis pipeline failed")
	sink := &captureLiveSink{execErr: wantErr}
	err := TrtcPublish(context.Background(), sink, _trtcTestNames, nil, time.Now(), _trtcTestTracks, nil, nil)
	if !errors.Is(err, wantErr) {
		t.Fatalf("pipeline error = %v, want wrapped %v", err, wantErr)
	}
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

// setKeys lists captured SET keys for failure messages.
func setKeys(s *captureLiveSink) []string {
	out := make([]string, 0, len(s.sets))
	for _, w := range s.sets {
		out = append(out, w.key)
	}
	return out
}

// _trtcTestNames is the station-name fixture the TRTC live tests resolve
// against (mrt_station is not available in unit tests).
var _trtcTestNames = map[string][]string{
	"台北車站":  {"BL12", "R10"},
	"南港展覽館": {"BL23", "BR24"},
	"頂埔":    {"BL01"},
}

// setWrite records one pipelined SET.
type setWrite struct {
	key   string
	value []byte
	ttl   time.Duration
}

// hsetWrite records one pipelined HSET.
type hsetWrite struct {
	key   string
	field string
	value string
}

// publishWrite records one pipelined PUBLISH.
type publishWrite struct {
	channel string
	value   []byte
}

// expireWrite records one pipelined EXPIRE.
type expireWrite struct {
	key string
	ttl time.Duration
}

type capturePipe struct {
	sink                *captureLiveSink
	pendingOwnedKey     string
	pendingOwnedMembers []string
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
