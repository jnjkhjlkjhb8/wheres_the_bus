package history

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestHistorySnapshotWritersLogStoredRowsAndFailures(t *testing.T) {
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	for _, tc := range []struct {
		table string
		cols  []string
		write func(context.Context, Execer, [][]any)
	}{{"bus_stop_event", BusStopEventCols, SaveBusStopEvents}, {"bus_eta_history", _busEtaHistoryCols, SaveBusEtaHistory}} {
		t.Run(tc.table, func(t *testing.T) {
			logs.TakeAll()
			f := &fakeExecer{}
			tc.write(context.Background(), f, nil)
			if len(f.stmts) != 0 || logs.Len() != 0 {
				t.Fatal("empty snapshot wrote rows")
			}
			row := make([]any, len(tc.cols))
			for i := range row {
				row[i] = i
			}
			tc.write(context.Background(), f, [][]any{row})
			if len(f.stmts) != 1 || !strings.HasPrefix(f.stmts[0], "INSERT IGNORE INTO "+tc.table+" (") || logs.FilterMessage("inserted rows").Len() != 1 || logs.All()[0].ContextMap()["rows"] != int64(1) {
				t.Fatalf("writes=%v logs=%v", f.stmts, logs.All())
			}
			logs.TakeAll()
			f.err = errors.New("write failed")
			tc.write(context.Background(), f, [][]any{row})
			if logs.FilterMessage("insert error").Len() != 1 {
				t.Fatalf("failure logs=%v", logs.All())
			}
		})
	}
}

func TestLiveArchiveQueuesCompressedRowsAndReportsGaps(t *testing.T) {
	archive, flushes, gaps := _archive, _flushes, _liveArchiveGaps
	t.Cleanup(func() { _archive, _flushes, _liveArchiveGaps = archive, flushes, gaps })
	_archive = nil
	ArchiveLivePayload(DatasetBusFast, "Taipei", time.Now(), []byte("ignored"))
	_flushes = &Flusher{queue: make(chan Flush, 8), timeout: time.Second}
	_liveArchiveGaps = &liveArchiveGaps{}
	c := &archiveTestConn{}
	_archive = &archiver{db: archiveReaderDB(t, c)}
	at := time.Date(2026, 10, 10, 12, 0, 0, 0, time.FixedZone("UTC+8", 8*3600))
	payload := []byte(`[{"value":42}]`)
	ArchiveLivePayload(DatasetBusFast, "Taipei", at, nil)
	submitLiveArchiveRow(DatasetBusFast, "Taipei", at, nil)
	if len(_flushes.queue) != 0 {
		t.Fatal("empty payload queued")
	}
	ArchiveLivePayload(DatasetBusFast, "Taipei", at, payload)
	task := historyNativeQueuedArchive(t, _flushes.queue)
	if task.table != "live_archive_bus" || task.rows != 1 {
		t.Fatalf("task=%v", task)
	}
	task.write(context.Background())
	if len(c.args) != 4 || c.args[0].Value != DatasetBusFast || c.args[1].Value != "Taipei" || !c.args[2].Value.(time.Time).Equal(at) || c.args[2].Value.(time.Time).Location() != time.UTC {
		t.Fatalf("args=%v", c.args)
	}
	gz, err := gzip.NewReader(bytes.NewReader(c.args[3].Value.([]byte)))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := io.ReadAll(gz)
	_ = gz.Close()
	if err != nil || !bytes.Equal(raw, payload) {
		t.Fatalf("payload=%q %v", raw, err)
	}
	tap := LiveArchiveTap("bus_EstimatedTimeOfArrivalTaipei")
	if tap == nil {
		t.Fatal("tap missing")
	}
	if _, err := tap.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := tap.Close(); err != nil {
		t.Fatal(err)
	}
	task = historyNativeQueuedArchive(t, _flushes.queue)
	c.execErr = errors.New("archive unavailable")
	task.write(context.Background())
	ArchiveMQTTMessage("topic", payload)
	task = historyNativeQueuedArchive(t, _flushes.queue)
	if task.table != "live_archive" {
		t.Fatalf("MQTT table=%s", task.table)
	}
	c.execErr = nil
	task.write(context.Background())
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	ReportGaps()
	entries := logs.FilterMessage("archive coverage").All()
	if len(entries) != 3 {
		t.Fatalf("coverage=%v", entries)
	}
	expected := map[string][3]int64{DatasetBusFast: {1, 1, 0}, "live_bus_eta": {1, 0, 1}, DatasetMQTT: {1, 1, 0}}
	previous := ""
	for _, entry := range entries {
		fields := entry.ContextMap()
		dataset := fields["dataset"].(string)
		if dataset < previous {
			t.Fatal("coverage reports unsorted")
		}
		previous = dataset
		want := expected[dataset]
		if fields["seen"] != want[0] || fields["stored"] != want[1] || fields["missing"] != want[2] {
			t.Fatalf("coverage=%v", fields)
		}
	}
	logs.TakeAll()
	ReportGaps()
	if logs.Len() != 0 {
		t.Fatal("counts were not drained")
	}
}

func historyNativeQueuedArchive(t *testing.T, queue <-chan Flush) Flush {
	t.Helper()
	select {
	case task := <-queue:
		return task
	case <-time.After(5 * time.Second):
		t.Fatal("archive output was not queued")
		return Flush{}
	}
}
