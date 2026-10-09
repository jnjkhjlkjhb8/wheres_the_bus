// Command rider owns rider state and push delivery (ADR-0026):
//
//	rider api      the device, reminder, feedback and MRT tracking RPCs api forwards
//	rider worker   reminder and route-alert dispatch, MRT alight tracking, upkeep
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/obs"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/notify"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

const (
	// _dispatchTimeout bounds one scheduled-reminder or outbox tick.
	_dispatchTimeout = 25 * time.Second
	_shutdownGrace   = 30 * time.Second
	_bootTimeout     = 30 * time.Second
	// _reminderRetention matches the 30-day reminder history the app shows.
	_reminderRetention = 30 * 24 * time.Hour
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "rider exited with error: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 1 || (args[0] != "worker" && args[0] != "api") {
		return errors.New("usage: rider <api|worker>")
	}
	defer obs.Init("rider-" + args[0])()
	defer obs.Recover("main")
	if args[0] == "api" {
		return runAPI()
	}
	return runWorker()
}

func runWorker() error {
	rc := shared.ConnectRedis()
	defer func() {
		if err := rc.Close(); err != nil {
			zap.S().Errorw("failed", "component", "redis", "action", "close", "event", "failed", "err", err)
		}
	}()
	db := shared.ConnectDB("RIDER_DB_MAX_CONNS", 5)
	defer db.Close()
	_health = newHealthFile(defaultHealthFilePath())

	sender, err := notify.NewFirebaseSender(context.Background())
	if err != nil {
		return _oops.Wrapf(err, "init Firebase sender")
	}
	dispatcher := notify.NewDispatcher(notify.NewStore(db), sender)
	apns, err := notify.NewAPNSSender()
	if err != nil {
		return _oops.Wrapf(err, "init APNs sender")
	}
	pusher := notify.NewTrackPusher(sender, apns)

	bootCtx, bootCancel := context.WithTimeout(context.Background(), _bootTimeout)
	restoreReminderDemand(bootCtx, db, pipeline.NewRedisLiveSink(rc))
	bootCancel()

	r := cron.New(cron.WithSeconds())
	// Rail reminders fire on a schedule (fire_at = arrival - lead), not off a
	// live ETA. Nil-safe when push is disabled.
	_, _ = addStaticCron(r, "@every 30s", func() {
		pipeline.WithTimeout(_dispatchTimeout, func(ctx context.Context) {
			if err := dispatcher.FireScheduled(ctx); err != nil {
				zap.S().Errorw("failed", "component", "reminders", "action", "fire_scheduled", "event", "failed", "err", err)
			}
		})
	})
	_, _ = addStaticCron(r, "@every 15s", func() {
		pipeline.WithTimeout(_dispatchTimeout, func(ctx context.Context) {
			if _, err := drainRouteAlertOutbox(ctx, db, dispatcher); err != nil {
				zap.S().Errorw("failed", "component", "outbox", "action", "drain", "event", "failed", "err", err)
			}
		})
	})
	registerMrtTrackCron(r, rc, db, dispatcher, pusher)
	_, _ = addStaticCron(r, "0 40 4 * * *", func() {
		pipeline.RunDaily("pruneArrivalReminders", 10*time.Minute, func(ctx context.Context) error {
			return notify.NewStore(db).PruneReminders(ctx, time.Now().Add(-_reminderRetention))
		})
		pipeline.RunDaily("pruneRouteAlertOutbox", 10*time.Minute, func(ctx context.Context) error {
			return pruneRouteAlertOutbox(ctx, db)
		})
	})

	ctx, stop := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		newArrivalConsumer(rc, dispatcher).run(ctx)
	}()
	r.Start()
	_health.touch()

	waitForShutdown()
	stop()
	cronDone := r.Stop()
	drained := make(chan struct{})
	go func() {
		<-cronDone.Done()
		wg.Wait()
		close(drained)
	}()
	select {
	case <-drained:
		zap.S().Infow("jobs drained", "component", "boot", "action", "shutdown", "event", "jobs_drained")
	case <-time.After(_shutdownGrace):
		zap.S().Warnw("grace timeout", "component", "boot", "action", "shutdown", "event", "grace_timeout")
	}
	return nil
}

func addStaticCron(r *cron.Cron, spec string, job func()) (cron.EntryID, error) {
	guarded := cron.NewChain(cron.SkipIfStillRunning(cron.DefaultLogger)).Then(cron.FuncJob(func() {
		job()
		_health.touch()
	}))
	return r.AddJob(spec, guarded)
}

func waitForShutdown() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	zap.S().Infow("signal received", "component", "boot", "action", "shutdown", "event", "signal_received")
}
