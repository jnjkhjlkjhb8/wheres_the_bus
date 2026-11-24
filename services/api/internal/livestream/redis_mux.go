package livestream

import (
	"context"
	"sync"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/redis/go-redis/v9"
)

// _muxQueueSize bounds the frames buffered for one channel between the shared
// connection and LiveHub's forwarder, which drains it without blocking.
const _muxQueueSize = 64

// pubSubConn is the part of *redis.PubSub the mux drives, so tests can run it
// without a server.
type pubSubConn interface {
	Subscribe(ctx context.Context, channels ...string) error
	Unsubscribe(ctx context.Context, channels ...string) error
}

// redisMux carries every live channel over one Redis Pub/Sub connection.
// go-redis dials a dedicated connection with 64 KiB of buffers for each PubSub
// it hands out, so a PubSub per channel grew the api's connections and heap
// with every distinct route, stop and station being watched, and each dial ran
// while LiveHub held its lock.
type redisMux struct {
	ps pubSubConn

	mu     sync.Mutex
	subs   map[string]chan []byte
	closed bool
}

// newRedisMux starts routing in, the shared connection's messages, to the
// subscribed channels. When in closes, every open subscription closes too.
func newRedisMux(ps pubSubConn, in <-chan *redis.Message) *redisMux {
	m := &redisMux{ps: ps, subs: make(map[string]chan []byte)}
	go m.run(in)
	return m
}

// subscribe registers channel and returns its frames. A second subscribe to the
// same channel replaces the first and closes its frames: LiveHub resubscribes
// a channel before the entry it just dropped has released it.
func (m *redisMux) subscribe(ctx context.Context, channel string) (<-chan []byte, func(), error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, nil, errLiveSourceClosed
	}
	if previous, ok := m.subs[channel]; ok {
		close(previous)
	}
	out := make(chan []byte, _muxQueueSize)
	m.subs[channel] = out
	// A failed write leaves the channel in go-redis's set, which it subscribes
	// again when the connection comes back.
	if err := m.ps.Subscribe(ctx, channel); err != nil {
		obs.IncRedisError()
	}
	return out, func() { m.release(channel, out) }, nil
}

// release drops out if it is still channel's subscription. Redis commands are
// sent under m.mu so an UNSUBSCRIBE cannot land after a newer SUBSCRIBE.
func (m *redisMux) release(channel string, out chan []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.subs[channel] == out {
		m.dropLocked(channel, out)
	}
}

func (m *redisMux) dropLocked(channel string, out chan []byte) {
	delete(m.subs, channel)
	close(out)
	if err := m.ps.Unsubscribe(context.Background(), channel); err != nil {
		obs.IncRedisError()
	}
}

func (m *redisMux) run(in <-chan *redis.Message) {
	for msg := range in {
		m.deliver(msg.Channel, []byte(msg.Payload))
	}
	m.closeAll()
}

// deliver never blocks: one stalled channel would otherwise hold up every
// other channel on the connection. A full channel is dropped instead, which
// ends its streams so the clients reconnect and re-seed.
func (m *redisMux) deliver(channel string, payload []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out, ok := m.subs[channel]
	if !ok {
		return
	}
	select {
	case out <- payload:
	default:
		m.dropLocked(channel, out)
	}
}

func (m *redisMux) closeAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closed = true
	for channel, out := range m.subs {
		delete(m.subs, channel)
		close(out)
	}
}
