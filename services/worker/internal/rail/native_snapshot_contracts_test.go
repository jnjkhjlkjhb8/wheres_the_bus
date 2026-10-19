package rail

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/protobuf/proto"
)

type railSnapshotWrite struct {
	key   string
	value []byte
	ttl   time.Duration
}

type railSnapshotHash struct {
	key, field string
	value      any
}

type railSnapshotSink struct {
	pipeline.LiveSink
	pipe railSnapshotPipe
}

func (s *railSnapshotSink) Pipe() pipeline.LivePipe { return &s.pipe }

type railSnapshotPipe struct {
	sets, published []railSnapshotWrite
	hashes          []railSnapshotHash
	expires         map[string]time.Duration
	executions      int
}

func railSnapshotBytes(value any) []byte {
	switch value := value.(type) {
	case []byte:
		return append([]byte(nil), value...)
	case string:
		return []byte(value)
	default:
		panic("unexpected snapshot payload type")
	}
}

func (p *railSnapshotPipe) Set(key string, value any, ttl time.Duration) {
	p.sets = append(p.sets, railSnapshotWrite{key, railSnapshotBytes(value), ttl})
}
func (p *railSnapshotPipe) Publish(key string, value any) {
	p.published = append(p.published, railSnapshotWrite{key: key, value: railSnapshotBytes(value)})
}
func (p *railSnapshotPipe) HSet(key, field string, value any) {
	p.hashes = append(p.hashes, railSnapshotHash{key, field, value})
}
func (p *railSnapshotPipe) Expire(key string, ttl time.Duration) {
	if p.expires == nil {
		p.expires = make(map[string]time.Duration)
	}
	p.expires[key] = ttl
}
func (p *railSnapshotPipe) ReplaceOwnedKeys(string, []string, time.Duration) {
	panic("rail snapshots do not replace owned-key indexes")
}
func (p *railSnapshotPipe) Exec(context.Context) error { p.executions++; return nil }

func railSnapshotLogs(t *testing.T) *observer.ObservedLogs {
	t.Helper()
	core, logs := observer.New(zapcore.DebugLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	return logs
}

func railSnapshotCount(t *testing.T, logs *observer.ObservedLogs, component, event, field string, want int64) {
	t.Helper()
	found := false
	for _, entry := range logs.All() {
		values := entry.ContextMap()
		if values["component"] == component && values["event"] == event {
			if values[field] != want {
				t.Fatalf("%s %s=%v want %d", event, field, values[field], want)
			}
			found = true
		}
	}
	if !found {
		t.Fatalf("%s diagnostic missing", event)
	}
}

func railSnapshotFetch(t *testing.T, payload string) (pipeline.BoundFetch, *bool, *bool) {
	t.Helper()
	closed, acknowledged := false, false
	closeResponse := func() error { closed = true; return nil }
	t.Cleanup(func() {
		if !closed {
			_ = closeResponse()
		}
	})
	fetch := func(context.Context, string, string) (*shared.TDXFetch, error) {
		return &shared.TDXFetch{Modified: true, Decoder: json.NewDecoder(strings.NewReader(payload)), Close: closeResponse, Ack: func() error { acknowledged = true; return nil }}, nil
	}
	return fetch, &closed, &acknowledged
}

func TestRailNativeTraSnapshotPreservesTrainStationAndCompletionCount(t *testing.T) {
	logs := railSnapshotLogs(t)
	fetch, closed, acknowledged := railSnapshotFetch(t, `[{"TrainNo":"101","StationID":"0900","DelayTime":7},{"TrainNo":"202","StationID":"","DelayTime":13}]`)
	sink := &railSnapshotSink{}
	if err := TraEta(t.Context(), fetch, sink); err != nil {
		t.Fatal(err)
	}
	if !*closed || !*acknowledged || sink.pipe.executions != 1 {
		t.Fatalf("snapshot lifecycle closed=%v ack=%v executions=%d", *closed, *acknowledged, sink.pipe.executions)
	}
	railSnapshotCount(t, logs, "tra_eta", "delay_redis_success", "count", 2)
	stations := 0
	for _, h := range sink.pipe.hashes {
		if h.key == shared.TraDelayStationKey {
			stations++
			if h.field != "101" || h.value != "0900" {
				t.Fatalf("invalid train-station association: %+v", h)
			}
		}
	}
	if stations != 1 {
		t.Fatalf("station associations=%d want1", stations)
	}
	decoded := map[string]*models.TraDelays{}
	for _, write := range sink.pipe.sets {
		if write.ttl != pipeline.TraLiveTTL {
			t.Fatalf("snapshot TTL=%v", write.ttl)
		}
		value := new(models.TraDelays)
		if err := proto.Unmarshal(write.value, value); err != nil {
			t.Fatal(err)
		}
		decoded[write.key] = value
	}
	all := decoded[shared.TraDelayAllKey]
	if all == nil || len(all.Delay) != 2 || all.Delay["101"] != 7 || all.Delay["202"] != 13 {
		t.Fatalf("aggregate snapshot=%v", all)
	}
	for train, want := range map[string]int32{"101": 7, "202": 13} {
		got := decoded[shared.TraDelayTrainChannel(train)]
		if got == nil || len(got.Delay) != 1 || got.Delay[train] != want {
			t.Fatalf("per-train snapshot %s=%v", train, got)
		}
	}
	if sink.pipe.expires[shared.TraDelayHashKey] != pipeline.TraLiveTTL || sink.pipe.expires[shared.TraDelayStationKey] != pipeline.TraLiveTTL {
		t.Fatal("rail hash expiration missing")
	}
}

func TestRailNativeThsrSnapshotCountsTrainsAndPreservesDistinctSegments(t *testing.T) {
	logs := railSnapshotLogs(t)
	fetch, closed, acknowledged := railSnapshotFetch(t, `[{"TrainDate":"2026-01-01","Items":[{"TrainNo":"801","OriginStationID":"0990","DestinationStationID":"1000","StandardSeatStatus":"O","BusinessSeatStatus":"X"},{"TrainNo":"801","OriginStationID":"1000","DestinationStationID":"1010","StandardSeatStatus":"L","BusinessSeatStatus":"O"},{"TrainNo":"802","OriginStationID":"0990","DestinationStationID":"1010","StandardSeatStatus":"X","BusinessSeatStatus":"L"}]}]`)
	sink := &railSnapshotSink{}
	if err := ThsrAvailableSeats(t.Context(), fetch, sink); err != nil {
		t.Fatal(err)
	}
	if !*closed || !*acknowledged || sink.pipe.executions != 1 {
		t.Fatal("THSR successful snapshot was not committed and acknowledged")
	}
	railSnapshotCount(t, logs, "thsr_seats", "complete", "train_count", 2)
	if len(sink.pipe.sets) != 2 {
		t.Fatalf("train snapshots=%d want2", len(sink.pipe.sets))
	}
	for _, write := range sink.pipe.sets {
		if write.ttl != pipeline.ThsrSeatsLiveTTL {
			t.Fatalf("THSR TTL=%v", write.ttl)
		}
		var seats models.ThsrAvailableSeats
		if err := proto.Unmarshal(write.value, &seats); err != nil {
			t.Fatal(err)
		}
		switch {
		case strings.HasSuffix(write.key, ":801"):
			if len(seats.Segments) != 2 || seats.Segments[0].OriginStationId != "0990" || seats.Segments[0].DestinationStationId != "1000" || seats.Segments[0].StandardSeatStatus != "O" || seats.Segments[0].BusinessSeatStatus != "X" || seats.Segments[1].OriginStationId != "1000" || seats.Segments[1].DestinationStationId != "1010" || seats.Segments[1].StandardSeatStatus != "L" || seats.Segments[1].BusinessSeatStatus != "O" {
				t.Fatalf("train801 segments=%v", &seats)
			}
		case strings.HasSuffix(write.key, ":802"):
			if len(seats.Segments) != 1 || seats.Segments[0].OriginStationId != "0990" || seats.Segments[0].DestinationStationId != "1010" || seats.Segments[0].StandardSeatStatus != "X" || seats.Segments[0].BusinessSeatStatus != "L" {
				t.Fatalf("train802 segments=%v", &seats)
			}
		default:
			t.Fatalf("unexpected train snapshot key %q", write.key)
		}
	}
}

func railSnapshotMalformed(t *testing.T, run func(context.Context, pipeline.BoundFetch, pipeline.LiveSink) error, payload, component string) {
	t.Helper()
	logs := railSnapshotLogs(t)
	fetch, closed, acknowledged := railSnapshotFetch(t, payload)
	sink := &railSnapshotSink{}
	err := run(t.Context(), fetch, sink)
	var syntax *json.SyntaxError
	if !errors.As(err, &syntax) {
		t.Fatalf("malformed payload lost original syntax cause: %v", err)
	}
	if !*closed || *acknowledged || sink.pipe.executions != 0 {
		t.Fatalf("invalid snapshot lifecycle closed=%v ack=%v exec=%d", *closed, *acknowledged, sink.pipe.executions)
	}
	for _, entry := range logs.All() {
		fields := entry.ContextMap()
		if fields["component"] == component && (fields["event"] == "complete" || fields["event"] == "delay_redis_success") {
			t.Fatal("invalid snapshot reported successful completion")
		}
	}
}

func TestRailNativeTraMalformedSnapshotRetainsCauseAndNeverExecutes(t *testing.T) {
	railSnapshotMalformed(t, TraEta, `[{"TrainNo":"101","StationID":"0900","DelayTime":7},]`, "tra_eta")
}
func TestRailNativeThsrMalformedSnapshotRetainsCauseAndNeverExecutes(t *testing.T) {
	railSnapshotMalformed(t, ThsrAvailableSeats, `[{"Items":[{"TrainNo":"801","OriginStationID":"0990","DestinationStationID":"1000"}]},]`, "thsr_seats")
}
