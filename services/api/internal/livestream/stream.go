package livestream

import (
	"context"
	"errors"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
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
	// Touch keeps key alive for at least ttl, never shortening a longer TTL
	// such as a reminder's. It carries the demand signal to realtime and
	// nothing reads it back here, so a failure costs freshness rather than
	// correctness and is not returned.
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
	// Claim demand before subscribing: a cold city has nothing to send until
	// this first touch wakes realtime to fetch it.
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
	stream := liveStream{source: source, spec: spec, usable: usable, send: send}
	stream.touchDemand(ctx)
	return stream
}

type liveStream struct {
	source LiveSource
	spec   LiveStreamSpec
	usable func([]byte) bool
	send   func([]byte) error
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
	renew := time.NewTicker(_demandRefresh)
	defer renew.Stop()
	for {
		if err := s.step(ctx, ch, renew.C); err != nil {
			return err
		}
	}
}

// step handles the next frame or demand renewal. Demand is renewed on a timer,
// not on frames: a partition whose data stops changing publishes nothing, and
// demand that lapsed there would stop its fetches for good.
func (s *liveStream) step(ctx context.Context, ch <-chan []byte, renew <-chan time.Time) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-renew:
		s.touchDemand(ctx)
		return nil
	case val, ok := <-ch:
		return s.deliver(ch, val, ok)
	}
}

func (s *liveStream) deliver(ch <-chan []byte, val []byte, ok bool) error {
	if !ok {
		return s.closeCause(ch)
	}
	if !s.usable(val) {
		return nil
	}
	return s.send(val)
}

func (s *liveStream) touchDemand(ctx context.Context) {
	if s.spec.DemandKey != "" {
		s.source.Touch(ctx, s.spec.DemandKey, _demandTTL)
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

// Touch claims a demand key. Creating it means nobody was watching that
// partition, so realtime is woken to fetch it now rather than on its next
// tick. A Redis failure here only delays or stales the city's data, so it is
// counted and dropped rather than failing the stream that is otherwise working.
func (r RedisLiveSource) Touch(ctx context.Context, key string, ttl time.Duration) {
	created, err := shared.TouchLiveDemand(ctx, r.rc, key, ttl)
	if err != nil {
		obs.IncRedisError()
		return
	}
	if created {
		r.wake(ctx, key)
	}
}

// wake publishes the demand key that was just created. A lost wake only makes
// the first frame wait for the next tick.
func (r RedisLiveSource) wake(ctx context.Context, key string) {
	if err := r.rc.Publish(ctx, shared.LiveWakeChannel, key).Err(); err != nil {
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
