package history

import (
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"sort"
	"strings"
	"sync"
	"time"

	"go.uber.org/zap"
)

var _liveArchiveCols = []string{"dataset", "partition_val", "recorded_at", "payload"}

// The two retention classes are two tables, not a column: pruning is
// DROP PARTITION, which takes every dataset in the partition with it, so a
// partition cannot be dropped for the bus streams and kept for the metro ones.
const (
	_liveArchiveTable    = "live_archive"     // kept indefinitely
	_liveArchiveBusTable = "live_archive_bus" // kept 90 days
)

// liveArchiveTable routes a dataset to its retention class.
func liveArchiveTable(dataset string) string {
	if strings.HasPrefix(dataset, "live_bus") {
		return _liveArchiveBusTable
	}
	return _liveArchiveTable
}

var _liveArchiveStreams = []struct {
	prefix  string
	dataset string
}{
	{prefix: "bus_EstimatedTimeOfArrival", dataset: "live_bus_eta"},
	{prefix: "bus_RealTimeByFrequency", dataset: "live_bus_position"},
	{prefix: "bus_RealTimeNearStop", dataset: "live_bus_nearstop"},
	{prefix: "mrt_LiveBoard", dataset: "live_mrt_liveboard"},
	{prefix: "tra_delay", dataset: "live_tra"},
	{prefix: "thsr_availableseats", dataset: "live_thsr"},
}

// Datasets written by the streams that do not go through the TDX client: the
// Data.taipei bus blob, the Metro Taipei SOAP endpoints, and the alert feed.
const (
	DatasetBusFast = "live_bus_fast"
	DatasetMRT     = "live_mrt"
	DatasetMQTT    = "live_mqtt"
)

var _liveDataTaipeiBlobs = map[string]bool{
	"GetBusData":      true,
	"GetBusEvent":     true,
	"BusSeatEvent":    true,
	"GetEstimateTime": true,
}

func IsLiveDataTaipeiBlob(name string) bool { return _liveDataTaipeiBlobs[name] }

// liveArchiveStream resolves a fetch name to its dataset and partition, and
// reports whether the stream is archived at all.
func liveArchiveStream(name string) (dataset, partition string, ok bool) {
	for _, s := range _liveArchiveStreams {
		if rest, found := strings.CutPrefix(name, s.prefix); found {
			return s.dataset, rest, true
		}
	}
	return "", "", false
}

func ArchiveMQTTMessage(topic string, payload []byte) {
	ArchiveLivePayload(DatasetMQTT, topic, time.Now(), payload)
}

// LiveArchiveTap is the shared.TDXTap the live TDX client is built with. It
// returns nil — meaning "not observed" — for a stream off the whitelist and for
// every environment without an archive host, which is all of them but prod.
func LiveArchiveTap(name string) io.WriteCloser {
	dataset, partition, ok := liveArchiveStream(name)
	if !ok || Target() == nil {
		return nil
	}
	return newLiveArchiveSink(dataset, partition, time.Now())
}

type liveArchiveSink struct {
	dataset    string
	partition  string
	recordedAt time.Time
	buf        bytes.Buffer
	gz         *gzip.Writer
}

func newLiveArchiveSink(dataset, partition string, recordedAt time.Time) *liveArchiveSink {
	s := &liveArchiveSink{dataset: dataset, partition: partition, recordedAt: recordedAt}
	s.gz = gzip.NewWriter(&s.buf)
	_liveArchiveGaps.due(dataset)
	return s
}

func (s *liveArchiveSink) Write(p []byte) (int, error) {
	return s.gz.Write(p)
}

// Close finishes the gzip stream and queues the row. The write itself happens on
// the flusher, off the live tick's clock: these bytes describe a snapshot that
// has already been published to Redis, and nothing downstream waits on them.
func (s *liveArchiveSink) Close() error {
	if err := s.gz.Close(); err != nil {
		zap.S().Errorw("compress error",
			"component", "live_archive", "dataset", s.dataset, "partition", s.partition, "err", err)
		return err
	}
	submitLiveArchiveRow(s.dataset, s.partition, s.recordedAt, s.buf.Bytes())
	return nil
}

func submitLiveArchiveRow(dataset, partition string, recordedAt time.Time, payload []byte) {
	target := Target()
	if target == nil || len(payload) == 0 {
		return
	}
	row := []any{dataset, partition, recordedAt, payload}
	table := liveArchiveTable(dataset)
	Submit(table, 1, func(ctx context.Context) {
		if err := Insert(ctx, target, table, _liveArchiveCols, [][]any{row}); err != nil {
			zap.S().Errorw("insert error",
				"component", "live_archive", "dataset", dataset, "partition", partition, "err", err)
			return
		}
		_liveArchiveGaps.stored(dataset)
	})
}

func ArchiveLivePayload(dataset, partition string, recordedAt time.Time, payload []byte) {
	if Target() == nil || len(payload) == 0 {
		return
	}
	_liveArchiveGaps.due(dataset)
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(payload); err != nil {
		zap.S().Errorw("compress error",
			"component", "live_archive", "dataset", dataset, "partition", partition, "err", err)
		return
	}
	if err := zw.Close(); err != nil {
		zap.S().Errorw("compress error",
			"component", "live_archive", "dataset", dataset, "partition", partition, "err", err)
		return
	}
	submitLiveArchiveRow(dataset, partition, recordedAt, buf.Bytes())
}

type liveArchiveGaps struct {
	mu     sync.Mutex
	counts map[string]*liveArchiveCount
}

type liveArchiveCount struct {
	seen   int
	stored int
}

var _liveArchiveGaps = &liveArchiveGaps{}

func (g *liveArchiveGaps) due(dataset string) {
	g.bump(dataset, func(c *liveArchiveCount) { c.seen++ })
}

func (g *liveArchiveGaps) stored(dataset string) {
	g.bump(dataset, func(c *liveArchiveCount) { c.stored++ })
}

func (g *liveArchiveGaps) bump(dataset string, fn func(*liveArchiveCount)) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.counts == nil {
		g.counts = make(map[string]*liveArchiveCount)
	}
	c, ok := g.counts[dataset]
	if !ok {
		c = &liveArchiveCount{}
		g.counts[dataset] = c
	}
	fn(c)
}

// drain returns the counts accumulated since the last drain and clears them, so
// each report covers one interval rather than all of
func (g *liveArchiveGaps) drain() map[string]liveArchiveCount {
	g.mu.Lock()
	defer g.mu.Unlock()
	out := make(map[string]liveArchiveCount, len(g.counts))
	for dataset, c := range g.counts {
		out[dataset] = *c
	}
	g.counts = nil
	return out
}

func ReportGaps() {
	counts := _liveArchiveGaps.drain()
	datasets := make([]string, 0, len(counts))
	for dataset := range counts {
		datasets = append(datasets, dataset)
	}
	sort.Strings(datasets)
	for _, dataset := range datasets {
		c := counts[dataset]
		zap.S().Infow("archive coverage",
			"component", "live_archive",
			"action", "coverage",
			"dataset", dataset,
			"seen", c.seen,
			"stored", c.stored,
			"missing", c.seen-c.stored,
		)
	}
}
