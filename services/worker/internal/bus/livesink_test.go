package bus

import (
	"bytes"
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"github.com/redis/go-redis/v9"
)

// Live-sink and live-source fakes. Other packages keep their own copies.

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

func (s *captureLiveSink) expireFor(key string) *expireWrite {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.expires {
		if s.expires[i].key == key {
			w := s.expires[i]
			return &w
		}
	}
	return nil
}
