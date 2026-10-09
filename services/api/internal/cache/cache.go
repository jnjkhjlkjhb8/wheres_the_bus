package cache

import (
	"sync"
	"sync/atomic"
	"time"
)

type ttlEntry struct {
	data      []byte
	expiresAt time.Time
}

type TTLCache struct {
	m sync.Map

	maxEntries int
	// entries tracks the live key count so set can tell when the cap is
	// reached. It is advisory: get/set race against each other, so a few
	// keys either way only shifts when the flush happens.
	entries atomic.Int64
}

func NewTTLCache() *TTLCache {
	return &TTLCache{}
}

func NewBoundedTTLCache(maxEntries int) *TTLCache {
	return &TTLCache{maxEntries: maxEntries}
}

func (c *TTLCache) Get(key string) ([]byte, bool) {
	v, ok := c.m.Load(key)
	if !ok {
		return nil, false
	}
	e, ok := v.(ttlEntry)
	if !ok {
		return nil, false
	}
	if time.Now().After(e.expiresAt) {
		c.Delete(key)
		return nil, false
	}
	return e.data, true
}

func (c *TTLCache) Set(key string, data []byte, ttl time.Duration) {
	_, loaded := c.m.Swap(key, ttlEntry{data: data, expiresAt: time.Now().Add(ttl)})
	if loaded || c.maxEntries <= 0 {
		return
	}
	if c.entries.Add(1) > int64(c.maxEntries) {
		c.Flush()
	}
}

func (c *TTLCache) Delete(key string) {
	if _, loaded := c.m.LoadAndDelete(key); loaded && c.maxEntries > 0 {
		c.entries.Add(-1)
	}
}

func (c *TTLCache) Flush() {
	c.m.Range(func(k, _ any) bool {
		c.m.Delete(k)
		return true
	})
	c.entries.Store(0)
}
