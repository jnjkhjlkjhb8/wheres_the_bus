package livestream

import (
	"context"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// DefaultSubscriberQueueSize bounds how many undelivered frames a single
// subscriber's downstream channel may hold before it is evicted as too slow.
const DefaultSubscriberQueueSize = 32

var errLiveSubscriberOverflow = status.Error(codes.Unavailable, "live stream subscriber fell behind, reconnect")

type HubStats struct {
	ActiveStreams      int64
	ActiveChannels     int64
	EvictedSubscribers int64
}

type liveHubEntry struct {
	upstreamClose func()
	subscribers   map[uint64]chan []byte
}

type LiveHub struct {
	source              LiveSource
	maxStreams          int64
	subscriberQueueSize int

	mu                 sync.Mutex
	entries            map[string]*liveHubEntry
	nextSubscriber     uint64
	activeStreams      int64
	evictedSubscribers int64
	// closeReasons records why a specific downstream channel was closed, for
	// channels closed by evictSlowSubscriber. Absence means the generic
	// upstream-disconnect case: streamLive falls back to errLiveSourceClosed.
	closeReasons map[<-chan []byte]error
}

func NewLiveHub(source LiveSource, maxStreams int) *LiveHub {
	return NewLiveHubWithQueueSize(source, maxStreams, DefaultSubscriberQueueSize)
}

// NewLiveHubWithQueueSize is newLiveHub with an explicit per-subscriber
// queue bound; queueSize <= 0 falls back to defaultSubscriberQueueSize.
func NewLiveHubWithQueueSize(source LiveSource, maxStreams, queueSize int) *LiveHub {
	if queueSize <= 0 {
		queueSize = DefaultSubscriberQueueSize
	}
	return &LiveHub{
		source:              source,
		maxStreams:          int64(maxStreams),
		subscriberQueueSize: queueSize,
		entries:             make(map[string]*liveHubEntry),
		closeReasons:        make(map[<-chan []byte]error),
	}
}

func (h *LiveHub) Get(ctx context.Context, key string) ([]byte, bool) {
	return h.source.Get(ctx, key)
}

func (h *LiveHub) ScanKeys(ctx context.Context, pattern string) []string {
	return h.source.ScanKeys(ctx, pattern)
}

// Touch passes the demand signal straight through: the hub multiplexes
// subscriptions, but every subscriber renews its own city independently.
func (h *LiveHub) Touch(ctx context.Context, key string, ttl time.Duration) {
	h.source.Touch(ctx, key, ttl)
}

func (h *LiveHub) Subscribe(ctx context.Context, channel string) (<-chan []byte, func(), error) {
	h.mu.Lock()
	if h.maxStreams > 0 && h.activeStreams >= h.maxStreams {
		h.mu.Unlock()
		return nil, nil, status.Error(codes.ResourceExhausted, "live stream capacity reached")
	}

	entry := h.entries[channel]
	if entry == nil {
		upstream, upstreamClose, err := h.source.Subscribe(context.WithoutCancel(ctx), channel)
		if err != nil {
			h.mu.Unlock()
			return nil, nil, err
		}
		entry = &liveHubEntry{
			upstreamClose: upstreamClose,
			subscribers:   make(map[uint64]chan []byte),
		}
		h.entries[channel] = entry
		go h.forward(channel, entry, upstream)
	}

	h.nextSubscriber++
	id := h.nextSubscriber
	downstream := make(chan []byte, h.subscriberQueueSize)
	entry.subscribers[id] = downstream
	h.activeStreams++
	h.mu.Unlock()

	var once sync.Once
	closeSubscriber := func() {
		once.Do(func() {
			h.unsubscribe(channel, entry, id, downstream)
		})
	}
	return downstream, closeSubscriber, nil
}

func (h *LiveHub) unsubscribe(channel string, entry *liveHubEntry, id uint64, downstream chan []byte) {
	h.mu.Lock()
	if h.entries[channel] != entry {
		delete(h.closeReasons, downstream)
		h.mu.Unlock()
		return
	}
	current, ok := entry.subscribers[id]
	if !ok {
		delete(h.closeReasons, downstream)
		h.mu.Unlock()
		return
	}
	delete(entry.subscribers, id)
	delete(h.closeReasons, current)
	close(current)
	h.activeStreams--
	upstreamClose := h.closeEntryIfEmptyLocked(channel, entry)
	h.mu.Unlock()

	if upstreamClose != nil {
		upstreamClose()
	}
}

// Caller holds h.mu. Disconnect on overflow rather than silently losing deltas.
func (h *LiveHub) evictSlowSubscriber(entry *liveHubEntry, id uint64, downstream chan []byte) {
	delete(entry.subscribers, id)
	h.activeStreams--
	h.evictedSubscribers++
	h.closeReasons[downstream] = errLiveSubscriberOverflow
	close(downstream)
}

// closeEntryIfEmptyLocked removes channel's entry once its subscriber set is
// empty and returns the upstream close func to invoke after unlocking (nil
// if the entry is still in use or already gone). Callers must hold h.mu.
func (h *LiveHub) closeEntryIfEmptyLocked(channel string, entry *liveHubEntry) func() {
	if h.entries[channel] != entry || len(entry.subscribers) != 0 {
		return nil
	}
	delete(h.entries, channel)
	return entry.upstreamClose
}

func (h *LiveHub) forward(channel string, entry *liveHubEntry, upstream <-chan []byte) {
	for payload := range upstream {
		h.mu.Lock()
		if h.entries[channel] != entry {
			h.mu.Unlock()
			return
		}
		for id, downstream := range entry.subscribers {
			select {
			case downstream <- payload:
			default:
				// The subscriber's bounded queue is full: it is falling
				// behind. Evict it rather than dropping or replacing this
				// frame, so no distinct delta is silently lost.
				h.evictSlowSubscriber(entry, id, downstream)
			}
		}
		upstreamClose := h.closeEntryIfEmptyLocked(channel, entry)
		h.mu.Unlock()
		if upstreamClose != nil {
			upstreamClose()
		}
	}

	var upstreamClose func()
	h.mu.Lock()
	if h.entries[channel] == entry {
		delete(h.entries, channel)
		upstreamClose = entry.upstreamClose
		for id, downstream := range entry.subscribers {
			delete(entry.subscribers, id)
			delete(h.closeReasons, downstream)
			close(downstream)
			h.activeStreams--
		}
	}
	h.mu.Unlock()

	if upstreamClose != nil {
		upstreamClose()
	}
}

// subscriptionCloseCause reports why ch was closed when the cause is a
// specific, reconnectable per-subscriber event (overflow eviction) rather
// than a generic upstream disconnect. It satisfies liveSourceCloseCause.
func (h *LiveHub) subscriptionCloseCause(ch <-chan []byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	err := h.closeReasons[ch]
	delete(h.closeReasons, ch)
	return err
}

func (h *LiveHub) Stats() HubStats {
	h.mu.Lock()
	defer h.mu.Unlock()
	return HubStats{
		ActiveStreams:      h.activeStreams,
		ActiveChannels:     int64(len(h.entries)),
		EvictedSubscribers: h.evictedSubscribers,
	}
}
