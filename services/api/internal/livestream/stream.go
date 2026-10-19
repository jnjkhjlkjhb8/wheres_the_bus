package livestream

import (
	"context"
	"errors"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/grpc"
)

// LiveSource is the seam between live-stream handlers and Redis. Two adapters
// satisfy it: redisLiveSource in production and fakeLiveSource in tests.
type LiveSource interface {
	// Get returns the current payload for key; ok=false when the key is
	// missing or the read failed.
	Get(ctx context.Context, key string) ([]byte, bool)
	// ScanKeys returns every key matching pattern; best-effort, a failed
	// scan returns what was collected so far.
	ScanKeys(ctx context.Context, pattern string) []string
	Subscribe(ctx context.Context, channel string) (<-chan []byte, func(), error)
	// Touch writes key with ttl, replacing any existing TTL. It carries the
	// demand signal to functions and nothing reads it back here, so a failure
	// costs freshness rather than correctness and is not returned.
	Touch(ctx context.Context, key string, ttl time.Duration)
}

// LiveStreamSpec describes one gRPC live stream: which channel to follow,
// which keys seed a new subscriber, and which payloads are worth sending.
type LiveStreamSpec struct {
	Channel   string
	SeedKeys  []string
	SeedScan  string // optional SCAN pattern; matches seed in key order returned
	Usable    func([]byte) bool
	DemandKey string
}

const (
	_demandTTL     = 10 * time.Minute
	_demandRefresh = 4 * time.Minute
)

var errLiveSourceClosed = errors.New("live source subscription closed")

type liveSourceCloseCause interface {
	subscriptionCloseCause(ch <-chan []byte) error
}

func StreamLive(ctx context.Context, src LiveSource, spec LiveStreamSpec, send func([]byte) error) error {
	// Claim demand before subscribing: a cold city has no frames to renew from,
	// so this first touch is what gets it polled often enough to produce one.
	stream := newLiveStream(ctx, src, spec, send)

	ch, closeSub, err := src.Subscribe(ctx, spec.Channel)
	if err != nil {
		return err
	}
	defer closeSub()
	_ = grpc.SendHeader(ctx, nil)
	// Every return past this point ends an established stream (client
	// disconnect, upstream close, or send failure); a subscribe failure above
	// never started one, so it is not counted here.
	defer obs.IncStreamDisconnect()
	if err := stream.seed(ctx); err != nil {
		return err
	}
	return stream.forward(ctx, ch)
}

func newLiveStream(ctx context.Context, source LiveSource, spec LiveStreamSpec, send func([]byte) error) liveStream {
	usable := spec.Usable
	if usable == nil {
		usable = func(b []byte) bool { return len(b) > 0 }
	}
	touched := time.Now()
	if spec.DemandKey != "" {
		source.Touch(ctx, spec.DemandKey, _demandTTL)
	}
	return liveStream{source: source, spec: spec, usable: usable, send: send, touched: touched}
}

type liveStream struct {
	source  LiveSource
	spec    LiveStreamSpec
	usable  func([]byte) bool
	send    func([]byte) error
	touched time.Time
}

func (s *liveStream) seed(ctx context.Context) error {
	for _, key := range s.seedKeys(ctx) {
		if err := s.sendSeed(ctx, key); err != nil {
			return err
		}
	}
	return nil
}

func (s *liveStream) seedKeys(ctx context.Context) []string {
	keys := s.spec.SeedKeys
	if s.spec.SeedScan != "" {
		keys = append(keys, s.source.ScanKeys(ctx, s.spec.SeedScan)...)
	}
	return keys
}

func (s *liveStream) sendSeed(ctx context.Context, key string) error {
	val, ok := s.source.Get(ctx, key)
	if !ok || !s.usable(val) {
		return nil
	}
	return s.send(val)
}

func (s *liveStream) forward(ctx context.Context, ch <-chan []byte) error {
	for {
		val, err := s.nextFrame(ctx, ch)
		if err != nil {
			return err
		}
		if err := s.sendFrame(ctx, val); err != nil {
			return err
		}
	}
}

func (s *liveStream) nextFrame(ctx context.Context, ch <-chan []byte) ([]byte, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case val, ok := <-ch:
		if !ok {
			return nil, s.closeCause(ch)
		}
		return val, nil
	}
}

func (s *liveStream) sendFrame(ctx context.Context, val []byte) error {
	s.refreshDemand(ctx, time.Now())
	if !s.usable(val) {
		return nil
	}
	return s.send(val)
}

func (s *liveStream) refreshDemand(ctx context.Context, now time.Time) {
	if s.spec.DemandKey != "" && now.Sub(s.touched) >= _demandRefresh {
		s.source.Touch(ctx, s.spec.DemandKey, _demandTTL)
		s.touched = now
	}
}

func (s *liveStream) closeCause(ch <-chan []byte) error {
	if withCause, hasCause := s.source.(liveSourceCloseCause); hasCause {
		if cause := withCause.subscriptionCloseCause(ch); cause != nil {
			return cause
		}
	}
	zap.S().Infow("source closed",
		"component", "grpc",
		"action", "live_stream",
		"event", "source_closed",
		"channel", s.spec.Channel,
	)
	return errLiveSourceClosed
}

// RedisLiveSource adapts *redis.Client to the liveSource seam.
type RedisLiveSource struct {
	rc *redis.Client
}

// NewRedisLiveSource builds the Redis-backed LiveSource the router streams from.
func NewRedisLiveSource(rc *redis.Client) RedisLiveSource {
	return RedisLiveSource{rc: rc}
}

var _ LiveSource = RedisLiveSource{}

func (r RedisLiveSource) Get(ctx context.Context, key string) ([]byte, bool) {
	val, err := r.rc.Get(ctx, key).Bytes()
	if err != nil {
		// redis.Nil means the key is simply absent -- expected traffic, not a
		// Redis health signal -- so only a real failure counts here.
		if !errors.Is(err, redis.Nil) {
			obs.IncRedisError()
		}
		return nil, false
	}
	return val, true
}

// Touch renews a demand key. A Redis failure here only means the city it names
// may drop to its reduced cadence, so it is counted and dropped rather than
// failing the stream that is otherwise working.
func (r RedisLiveSource) Touch(ctx context.Context, key string, ttl time.Duration) {
	if err := r.rc.Set(ctx, key, "1", ttl).Err(); err != nil {
		obs.IncRedisError()
	}
}

func (r RedisLiveSource) ScanKeys(ctx context.Context, pattern string) []string {
	var out []string
	var cursor uint64
	for {
		keys, next, err := r.rc.Scan(ctx, cursor, pattern, 20).Result()
		if err != nil {
			obs.IncRedisError()
			return out
		}
		out = append(out, keys...)
		cursor = next
		if cursor == 0 {
			return out
		}
	}
}

func (r RedisLiveSource) Subscribe(ctx context.Context, channel string) (<-chan []byte, func(), error) {
	sub := r.rc.Subscribe(ctx, channel)
	out := make(chan []byte)
	done := make(chan struct{})
	go func() {
		defer close(out)
		forwardRedisSubscription(done, sub.Channel(), out)
	}()
	return out, func() {
		close(done)
		_ = sub.Close()
	}, nil
}

func forwardRedisSubscription(done <-chan struct{}, in <-chan *redis.Message, out chan<- []byte) {
	for {
		msg, ok := nextRedisMessage(done, in)
		if !ok {
			return
		}
		if !forwardRedisMessage(done, msg, out) {
			return
		}
	}
}

func nextRedisMessage(done <-chan struct{}, in <-chan *redis.Message) (*redis.Message, bool) {
	select {
	case <-done:
		return nil, false
	case msg, ok := <-in:
		return msg, ok
	}
}

func forwardRedisMessage(done <-chan struct{}, msg *redis.Message, out chan<- []byte) bool {
	select {
	case out <- []byte(msg.Payload):
		return true
	case <-done:
		return false
	}
}
