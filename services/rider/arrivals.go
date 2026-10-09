package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/riderevent"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	// _arrivalMaxAge drops events too old to act on: an arrival two minutes
	// stale has already happened, and firing its reminder now would be wrong.
	_arrivalMaxAge = 2 * time.Minute
	// _arrivalReclaimIdle is how long an event may sit unacknowledged with a
	// consumer before another one takes it: a consumer that crashed mid-batch.
	_arrivalReclaimIdle = time.Minute
	_arrivalBatch       = 100
	_arrivalBlock       = 5 * time.Second
)

// arrivalHandler is the dispatch side; *notify.Dispatcher in production.
type arrivalHandler interface {
	Arrivals(context.Context, []riderevent.ArrivalEvent) error
}

type arrivalConsumer struct {
	rc       *redis.Client
	handler  arrivalHandler
	consumer string
	now      func() time.Time
}

func newArrivalConsumer(rc *redis.Client, handler arrivalHandler) *arrivalConsumer {
	name, err := os.Hostname()
	if err != nil || name == "" {
		name = "rider-worker"
	}
	return &arrivalConsumer{rc: rc, handler: handler, consumer: name, now: time.Now}
}

// run reads the arrival stream until ctx ends. Each entry is acknowledged only
// after dispatch returns, so a crash leaves it pending for reclaim.
func (c *arrivalConsumer) run(ctx context.Context) {
	if err := c.ensureGroup(ctx); err != nil {
		zap.S().Errorw("failed", "component", "arrivals", "action", "create_group", "event", "failed", "err", err)
	}
	for ctx.Err() == nil {
		if err := c.reclaim(ctx); err != nil && ctx.Err() == nil {
			zap.S().Warnw("failed", "component", "arrivals", "action", "reclaim", "event", "failed", "err", err)
		}
		streams, err := c.rc.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group:    riderevent.Group,
			Consumer: c.consumer,
			Streams:  []string{riderevent.StreamKey, ">"},
			Count:    _arrivalBatch,
			Block:    _arrivalBlock,
		}).Result()
		if errors.Is(err, redis.Nil) || ctx.Err() != nil {
			continue
		}
		if err != nil {
			zap.S().Warnw("failed", "component", "arrivals", "action", "read", "event", "failed", "err", err)
			if strings.Contains(err.Error(), "NOGROUP") {
				_ = c.ensureGroup(ctx)
			}
			sleepCtx(ctx, _arrivalBlock)
			continue
		}
		for _, s := range streams {
			c.handle(ctx, s.Messages)
		}
	}
}

func (c *arrivalConsumer) ensureGroup(ctx context.Context) error {
	err := c.rc.XGroupCreateMkStream(ctx, riderevent.StreamKey, riderevent.Group, "$").Err()
	if err != nil && strings.Contains(err.Error(), "BUSYGROUP") {
		return nil
	}
	return err
}

func (c *arrivalConsumer) reclaim(ctx context.Context) error {
	msgs, _, err := c.rc.XAutoClaim(ctx, &redis.XAutoClaimArgs{
		Stream:   riderevent.StreamKey,
		Group:    riderevent.Group,
		Consumer: c.consumer,
		MinIdle:  _arrivalReclaimIdle,
		Start:    "0-0",
		Count:    _arrivalBatch,
	}).Result()
	if err != nil {
		return err
	}
	c.handle(ctx, msgs)
	return nil
}

// handle dispatches each entry and acknowledges it once dispatch succeeded or
// the entry is too old or unreadable to ever succeed.
func (c *arrivalConsumer) handle(ctx context.Context, msgs []redis.XMessage) {
	for _, msg := range msgs {
		events, at, err := riderevent.Decode(msg)
		switch {
		case err != nil:
			zap.S().Errorw("dropped", "component", "arrivals", "event", "undecodable", "id", msg.ID, "err", err)
		case c.now().Sub(at) > _arrivalMaxAge:
			zap.S().Warnw("dropped", "component", "arrivals", "event", "stale", "id", msg.ID, "age", c.now().Sub(at))
		default:
			dispatchCtx, cancel := context.WithTimeout(ctx, _dispatchTimeout)
			err := c.handler.Arrivals(dispatchCtx, events)
			cancel()
			if err != nil {
				// Left pending: the next reclaim retries it until it ages out.
				zap.S().Warnw("failed", "component", "arrivals", "action", "dispatch", "event", "failed", "id", msg.ID, "err", err)
				continue
			}
		}
		if err := c.rc.XAck(ctx, riderevent.StreamKey, riderevent.Group, msg.ID).Err(); err != nil {
			zap.S().Warnw("failed", "component", "arrivals", "action", "ack", "event", "failed", "id", msg.ID, "err", err)
		}
	}
}

func sleepCtx(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
