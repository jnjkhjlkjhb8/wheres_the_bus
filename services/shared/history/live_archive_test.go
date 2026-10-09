package history

import (
	"bytes"
	"compress/gzip"
	"io"
	"testing"
	"time"
)

// The whitelist decides both what is archived and where its retention is
// expressed, so a stream's dataset and the partition carved out of the fetch
// name are worth pinning.
func TestLiveArchiveStreamResolvesDatasetAndPartition(t *testing.T) {
	tests := []struct {
		name      string
		fetch     string
		dataset   string
		partition string
		ok        bool
	}{
		{name: "bus eta carries its city", fetch: "bus_EstimatedTimeOfArrivalTaipei", dataset: "live_bus_eta", partition: "Taipei", ok: true},
		{name: "bus position carries its city", fetch: "bus_RealTimeByFrequencyTaichung", dataset: "live_bus_position", partition: "Taichung", ok: true},
		{name: "nationwide fetch has no partition", fetch: "tra_delay", dataset: "live_tra", ok: true},
		{name: "bike is deliberately off the list", fetch: "bike_availabilityTaipei"},
		{name: "an unknown fetch is not archived", fetch: "something_new"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dataset, partition, ok := liveArchiveStream(tt.fetch)
			if ok != tt.ok {
				t.Fatalf("archived = %v, want %v", ok, tt.ok)
			}
			if dataset != tt.dataset || partition != tt.partition {
				t.Errorf("got %q/%q, want %q/%q", dataset, partition, tt.dataset, tt.partition)
			}
		})
	}
}

// Retention is the table, because DROP PARTITION cannot spare one dataset inside
// a partition. A bus stream landing in the permanent table would be kept forever;
// a metro stream landing in the pruned one would be deleted after 90 days.
func TestLiveArchiveTableSplitsByRetention(t *testing.T) {
	for dataset, want := range map[string]string{
		"live_bus_eta":       _liveArchiveBusTable,
		"live_bus_fast":      _liveArchiveBusTable,
		"live_bus_nearstop":  _liveArchiveBusTable,
		"live_mrt":           _liveArchiveTable,
		"live_tra":           _liveArchiveTable,
		"live_mqtt":          _liveArchiveTable,
		"live_mrt_liveboard": _liveArchiveTable,
	} {
		if got := liveArchiveTable(dataset); got != want {
			t.Errorf("%s went to %s, want %s", dataset, got, want)
		}
	}
}

// GetSpecTimeTable lands in raw_tdx and is archived there against its upstream
// version; archiving it here as well would keep the same bytes twice under two
// different retention rules.
func TestLiveDataTaipeiBlobsExcludeTheStaticTimetable(t *testing.T) {
	if IsLiveDataTaipeiBlob("GetSpecTimeTable") {
		t.Error("GetSpecTimeTable is landed into raw_tdx; it must not be archived as live too")
	}
	if !IsLiveDataTaipeiBlob("GetEstimateTime") {
		t.Error("GetEstimateTime is the bus_fast ETA blob and must be archived")
	}
}

// With no archive host there is nothing to observe into, and the sink must not
// be created: it would compress a payload on the live tick for a row nobody can
// write.
func TestLiveArchiveTapIsNilWithoutAnArchiveHost(t *testing.T) {
	if tap := LiveArchiveTap("bus_EstimatedTimeOfArrivalTaipei"); tap != nil {
		t.Error("want no tap when ARCHIVE_MYSQL_DSN is unset")
	}
}

// The counters are what keeps a dropped payload from being invisible: without
// them a backlogged flusher produces an archive with holes that reads as
// complete.
func TestLiveArchiveGapsCountSeenAgainstStored(t *testing.T) {
	var g liveArchiveGaps
	g.due("live_bus_eta")
	g.due("live_bus_eta")
	g.stored("live_bus_eta")
	g.due("live_tra")
	g.stored("live_tra")

	counts := g.drain()
	if got := counts["live_bus_eta"]; got.seen != 2 || got.stored != 1 {
		t.Errorf("live_bus_eta = %+v, want one of two payloads stored", got)
	}
	if got := counts["live_tra"]; got.seen != 1 || got.stored != 1 {
		t.Errorf("live_tra = %+v, want a complete interval", got)
	}
	// Each report covers one interval, so a drain must leave nothing behind —
	// otherwise yesterday's gap is reported again every day forever.
	if rest := g.drain(); len(rest) != 0 {
		t.Errorf("drain left %d datasets behind", len(rest))
	}
}

// The sink compresses as the body streams past, so what reaches the row must
// still be the payload byte for byte.
func TestLiveArchiveSinkCompressesWhatItIsGiven(t *testing.T) {
	const body = `[{"StopUID":"TPE1234","EstimateTime":180}]`
	s := newLiveArchiveSink("live_bus_eta", "Taipei", time.Now())
	if _, err := s.Write([]byte(body)); err != nil {
		t.Fatalf("write payload: %v", err)
	}
	if err := s.gz.Close(); err != nil {
		t.Fatalf("finish gzip stream: %v", err)
	}
	if got := gunzip(t, s.buf.Bytes()); got != body {
		t.Errorf("payload is not verbatim:\n got %q\nwant %q", got, body)
	}
	// Compression is not a formality here: the 90-day bus retention was sized
	// against compressed payloads.
	if !bytes.HasPrefix(s.buf.Bytes(), []byte{0x1f, 0x8b}) {
		t.Error("payload is not a gzip stream")
	}
}

// gunzip decompresses one archived payload. The raw-archive tests keep their
// own copy: a four-line helper is cheaper to duplicate than to share.
func gunzip(t *testing.T, b []byte) string {
	t.Helper()
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatalf("open gzip stream: %v", err)
	}
	defer func() { _ = zr.Close() }()
	out, err := io.ReadAll(zr)
	if err != nil {
		t.Fatalf("read gzip stream: %v", err)
	}
	return string(out)
}
