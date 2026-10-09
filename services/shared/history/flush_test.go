package history

import (
	"context"
	"testing"
	"time"
)

func TestBusEtaFlusherRunsTaskOffTheCallersContext(t *testing.T) {
	f := &Flusher{queue: make(chan Flush, 1), workers: 1, timeout: time.Minute}
	// Checked inside the write, because the flusher cancels the context as soon
	// as the write returns.
	type seen struct {
		err      error
		deadline bool
	}
	ran := make(chan seen, 1)
	f.submit(Flush{table: "t", rows: 1, write: func(ctx context.Context) {
		_, ok := ctx.Deadline()
		ran <- seen{err: ctx.Err(), deadline: ok}
	}})

	select {
	case got := <-ran:
		if got.err != nil {
			t.Fatalf("flush context = %v, want live", got.err)
		}
		if !got.deadline {
			t.Fatal("flush context has no deadline")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("flush never ran")
	}
}

func TestFlushBudgetScalesWithRows(t *testing.T) {
	floor := 60 * time.Second
	for _, tc := range []struct {
		rows int
		want time.Duration
	}{
		{rows: 0, want: floor},
		{rows: 1, want: floor},
		{rows: RowsPerInsert - 1, want: floor},
		{rows: RowsPerInsert, want: floor + _flushPerBatch},
		{rows: 21353, want: floor + 21*_flushPerBatch},
	} {
		if got := flushBudget(floor, tc.rows); got != tc.want {
			t.Errorf("flushBudget(%v, %d) = %v, want %v", floor, tc.rows, got, tc.want)
		}
	}
}

// A database that cannot keep up must drop batches rather than queue an
// unbounded backlog of increasingly stale rows.
func TestBusEtaFlusherDropsWhenQueueFull(t *testing.T) {
	// Zero workers: nothing drains, so the queue state is deterministic.
	f := &Flusher{queue: make(chan Flush, 2), timeout: time.Minute}
	for i := range 5 {
		f.submit(Flush{table: "t", rows: i, write: func(context.Context) {}})
	}
	if len(f.queue) != 2 {
		t.Fatalf("queued = %d, want 2", len(f.queue))
	}
}
