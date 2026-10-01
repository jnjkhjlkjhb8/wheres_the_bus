package history

import (
	"context"
	"sync"
	"time"

	"go.uber.org/zap"
)

const (
	_flushTimeout  = 60 * time.Second
	_flushPerBatch = 5 * time.Second
	_flushDepth    = 8
	_flushWorkers  = 2
)

// flushBudget is how long one batch of rows may take.
func flushBudget(floor time.Duration, rows int) time.Duration {
	return floor + time.Duration(rows/RowsPerInsert)*_flushPerBatch
}

type Flush struct {
	table string
	rows  int
	write func(context.Context)
}

type Flusher struct {
	queue   chan Flush
	workers int
	timeout time.Duration
	start   sync.Once
	wg      sync.WaitGroup
}

var _flushes = &Flusher{
	queue:   make(chan Flush, _flushDepth),
	workers: _flushWorkers,
	timeout: _flushTimeout,
}

// submit hands one batch to the flusher, dropping it when the queue is full.
// Workers start on first use so a process that never writes history never spawns
// them (and a test can hold the queue still by declaring zero workers).
func (f *Flusher) submit(task Flush) {
	f.start.Do(func() {
		for range f.workers {
			f.wg.Add(1)
			go func() {
				defer f.wg.Done()
				for t := range f.queue {
					ctx, cancel := context.WithTimeout(context.Background(), flushBudget(f.timeout, t.rows))
					t.write(ctx)
					cancel()
				}
			}()
		}
	})
	select {
	case f.queue <- task:
	default:
		zap.S().Warnw("dropped",
			"component", "bus_eta",
			"action", "flush",
			"event", "dropped",
			"table", task.table,
			"rows", task.rows,
			"reason", "queue_full",
		)
	}
}

// Close stops the flusher from accepting further work and waits for its
// workers to drain the queue and exit.
func (f *Flusher) Close() {
	close(f.queue)
	f.wg.Wait()
}

func Submit(table string, rows int, write func(context.Context)) {
	_flushes.submit(Flush{table: table, rows: rows, write: write})
}

// CloseFlusher drains the queue and waits for the workers at shutdown.
func CloseFlusher() { _flushes.Close() }
