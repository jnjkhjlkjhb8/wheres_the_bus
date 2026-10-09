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
	usable := spec.Usable
	if usable == nil {
		usable = func(b []byte) bool { return len(b) > 0 }
	}

	// Claim demand before subscribing: a cold city has no frames to renew from,
	// so this first touch is what gets it polled often enough to produce one.
	touched := time.Now()
	if spec.DemandKey != "" {
		src.Touch(ctx, spec.DemandKey, _demandTTL)
	}

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

	keys := spec.SeedKeys
	if spec.SeedScan != "" {
		keys = append(keys, src.ScanKeys(ctx, spec.SeedScan)...)
	}
	for _, k := range keys {
		val, ok := src.Get(ctx, k)
		if !ok || !usable(val) {
			continue
		}
		if err := send(val); err != nil {
			return err
		}
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case val, ok := <-ch:
			if !ok {
				if withCause, hasCause := src.(liveSourceCloseCause); hasCause {
					if cause := withCause.subscriptionCloseCause(ch); cause != nil {
						return cause
					}
				}
				zap.S().Infow("source closed",
					"component", "grpc",
					"action", "live_stream",
					"event", "source_closed",
					"channel", spec.Channel,
				)
				return errLiveSourceClosed
			}
			if spec.DemandKey != "" && time.Since(touched) >= _demandRefresh {
				src.Touch(ctx, spec.DemandKey, _demandTTL)
				touched = time.Now()
			}
			if !usable(val) {
				continue
			}
			if err := send(val); err != nil {
				return err
			}
		}
	}
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
		in := sub.Channel()
		for {
			select {
			case <-done:
				return
			case msg, ok := <-in:
				if !ok {
					return
				}
				select {
				case out <- []byte(msg.Payload):
				case <-done:
					return
				}
			}
		}
	}()
	return out, func() {
		close(done)
		_ = sub.Close()
	}, nil
}
