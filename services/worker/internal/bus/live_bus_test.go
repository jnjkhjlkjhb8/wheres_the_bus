package bus

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

func TestBusPublishFailureDoesNotAckEitherFeed(t *testing.T) {
	prefix := busmodel.CityPrefix["Taipei"]
	predict.StaticMapCache().Delete(prefix)
	t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })

	src := &fakeLiveSource{fixtures: map[string][]byte{
		"bus_EstimatedTimeOfArrivalTaipei": []byte(`[]`),
		"bus_RealTimeByFrequencyTaipei":    []byte(`[]`),
	}}
	publishErr := errors.New("redis pipeline failed")
	sink := &captureLiveSink{execErr: publishErr}
	store := &fakeBusEtaStore{stops: []busmodel.StationMap{{
		StationUID: "STATION1", StationName: "站牌一", SubRouteUID: "TPE1",
		SubRouteName: "一路", StopUID: "STOP1", StopSequence: 1,
	}}}
	job := busLiveJob{
		fetch: pipeline.BindFetch(src, sink, busTestSpec()), sink: sink, store: store,
		notifier: &captureBusArrivalNotifier{}, now: time.Now,
	}

	err := job.runCity(context.Background(), "Taipei")
	if !errors.Is(err, publishErr) {
		t.Fatalf("runCity error = %v, want %v", err, publishErr)
	}
	if len(src.acked) != 0 {
		t.Fatalf("failed combined publish acked feeds: %v", src.acked)
	}
	if len(src.closed) != 2 {
		t.Fatalf("closed feeds = %v, want both feeds", src.closed)
	}
}

func TestBusAcknowledgesBothFeedsAfterPublish(t *testing.T) {
	prefix := busmodel.CityPrefix["Taipei"]
	predict.StaticMapCache().Delete(prefix)
	t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })

	src := &fakeLiveSource{fixtures: map[string][]byte{
		"bus_EstimatedTimeOfArrivalTaipei": []byte(`[]`),
		"bus_RealTimeByFrequencyTaipei":    []byte(`[]`),
	}}
	sink := &captureLiveSink{}
	store := &fakeBusEtaStore{stops: []busmodel.StationMap{{
		StationUID: "STATION1", StationName: "站牌一", SubRouteUID: "TPE1",
		SubRouteName: "一路", StopUID: "STOP1", StopSequence: 1,
	}}}
	job := busLiveJob{
		fetch: pipeline.BindFetch(src, sink, busTestSpec()), sink: sink, store: store,
		notifier: &captureBusArrivalNotifier{}, now: time.Now,
	}

	if err := job.runCity(context.Background(), "Taipei"); err != nil {
		t.Fatalf("runCity: %v", err)
	}
	want := []string{
		"bus_EstimatedTimeOfArrivalTaipei",
		"bus_RealTimeByFrequencyTaipei",
	}
	if len(src.acked) != len(want) {
		t.Fatalf("acked feeds = %v, want %v", src.acked, want)
	}
	for i := range want {
		if src.acked[i] != want[i] {
			t.Fatalf("acked feed[%d] = %q, want %q", i, src.acked[i], want[i])
		}
	}
	if len(src.closed) != 2 {
		t.Fatalf("closed feeds = %v, want both feeds", src.closed)
	}
}

func TestReadBusFeedCacheRejectsNullButAcceptsEmptyArray(t *testing.T) {
	const key = "bus:raw:test"

	nullSink := &captureLiveSink{strings: map[string]string{key: `null`}}
	values, err := readBusFeedCache[busmodel.RawEstimated](context.Background(), nullSink, key)
	if !errors.Is(err, errBusFeedCacheMiss) {
		t.Fatalf("null cache error = %v, want %v", err, errBusFeedCacheMiss)
	}
	if values != nil {
		t.Fatalf("null cache values = %#v, want nil", values)
	}

	emptySink := &captureLiveSink{strings: map[string]string{key: `[]`}}
	values, err = readBusFeedCache[busmodel.RawEstimated](context.Background(), emptySink, key)
	if err != nil {
		t.Fatalf("empty array cache error = %v", err)
	}
	if values == nil || len(values) != 0 {
		t.Fatalf("empty array cache values = %#v, want non-nil empty slice", values)
	}
}

func TestBusOneModifiedFeedUsesCachedCounterpartAndAdvances(t *testing.T) {
	tests := []struct {
		name       string
		fixtures   map[string][]byte
		cachedKey  string
		modified   string
		writtenKey string
	}{
		{
			name: "ETA 200 positions 304",
			fixtures: map[string][]byte{
				"bus_EstimatedTimeOfArrivalTaipei": []byte(`[]`),
			},
			cachedKey:  shared.BusPositionRawKey("Taipei"),
			modified:   "bus_EstimatedTimeOfArrivalTaipei",
			writtenKey: shared.BusETARawKey("Taipei"),
		},
		{
			name: "ETA 304 positions 200",
			fixtures: map[string][]byte{
				"bus_RealTimeByFrequencyTaipei": []byte(`[]`),
			},
			cachedKey:  shared.BusETARawKey("Taipei"),
			modified:   "bus_RealTimeByFrequencyTaipei",
			writtenKey: shared.BusPositionRawKey("Taipei"),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			prefix := busmodel.CityPrefix["Taipei"]
			predict.StaticMapCache().Delete(prefix)
			t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })

			src := &fakeLiveSource{fixtures: tt.fixtures}
			sink := &captureLiveSink{strings: map[string]string{tt.cachedKey: `[]`}}
			store := &fakeBusEtaStore{stops: []busmodel.StationMap{{
				StationUID: "STATION1", StationName: "站牌一", SubRouteUID: "TPE1",
				SubRouteName: "一路", StopUID: "STOP1", StopSequence: 1,
			}}}
			job := busLiveJob{
				fetch: pipeline.BindFetch(src, sink, busTestSpec()), sink: sink, store: store,
				notifier: &captureBusArrivalNotifier{}, now: time.Now,
			}

			if err := job.runCity(context.Background(), "Taipei"); err != nil {
				t.Fatalf("runCity: %v", err)
			}
			if len(src.acked) != 1 || src.acked[0] != tt.modified {
				t.Fatalf("acked feeds = %v, want [%s]", src.acked, tt.modified)
			}
			if sw := sink.setFor(tt.writtenKey); sw == nil || sw.ttl != _busFeedCacheTTL || string(sw.value) != `[]` {
				t.Fatalf("raw feed cache %s = %+v, want ttl %v", tt.writtenKey, sw, _busFeedCacheTTL)
			}
			if ew := sink.expireFor(tt.cachedKey); ew == nil || ew.ttl != _busFeedCacheTTL {
				t.Fatalf("cached counterpart %s expiry = %+v, want ttl %v", tt.cachedKey, ew, _busFeedCacheTTL)
			}
			if sink.setFor(shared.BusRouteEtaKey("TPE1")) == nil {
				t.Fatal("combined route snapshot was not published")
			}
		})
	}
}

func TestBusMissingCachedCounterpartPersistsModifiedFeedAndInvalidatesMarker(t *testing.T) {
	prefix := busmodel.CityPrefix["Taipei"]
	predict.StaticMapCache().Delete(prefix)
	t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
	src := &fakeLiveSource{fixtures: map[string][]byte{
		"bus_EstimatedTimeOfArrivalTaipei": []byte(`[]`),
	}}
	sink := &captureLiveSink{}
	store := &fakeBusEtaStore{stops: []busmodel.StationMap{{
		StationUID: "STATION1", StationName: "站牌一", SubRouteUID: "TPE1",
		SubRouteName: "一路", StopUID: "STOP1", StopSequence: 1,
	}}}
	job := busLiveJob{
		fetch: pipeline.BindFetch(src, sink, busTestSpec()), sink: sink, store: store,
		notifier: &captureBusArrivalNotifier{}, now: time.Now,
	}

	if err := job.runCity(context.Background(), "Taipei"); err == nil {
		t.Fatal("missing cached counterpart returned nil error")
	}
	if sw := sink.setFor(shared.BusETARawKey("Taipei")); sw == nil || sw.ttl != _busFeedCacheTTL {
		t.Fatalf("ETA raw cache = %+v, want durable bounded cache", sw)
	}
	if len(src.acked) != 1 || src.acked[0] != "bus_EstimatedTimeOfArrivalTaipei" {
		t.Fatalf("acked feeds = %v, want modified ETA", src.acked)
	}
	if len(src.invalidated) != 1 || src.invalidated[0] != "bus_RealTimeByFrequencyTaipei" {
		t.Fatalf("invalidated feeds = %v, want missing position marker", src.invalidated)
	}
}

func TestBusIndependentAckFailuresLeaveBothRawFeedsDurable(t *testing.T) {
	for _, failedFeed := range []string{
		"bus_EstimatedTimeOfArrivalTaipei",
		"bus_RealTimeByFrequencyTaipei",
	} {
		t.Run(failedFeed, func(t *testing.T) {
			prefix := busmodel.CityPrefix["Taipei"]
			predict.StaticMapCache().Delete(prefix)
			t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
			ackErr := errors.New("marker write failed")
			src := &fakeLiveSource{
				fixtures: map[string][]byte{
					"bus_EstimatedTimeOfArrivalTaipei": []byte(`[]`),
					"bus_RealTimeByFrequencyTaipei":    []byte(`[]`),
				},
				ackErrors: map[string]error{failedFeed: ackErr},
			}
			sink := &captureLiveSink{}
			store := &fakeBusEtaStore{stops: []busmodel.StationMap{{
				StationUID: "STATION1", StationName: "站牌一", SubRouteUID: "TPE1",
				SubRouteName: "一路", StopUID: "STOP1", StopSequence: 1,
			}}}
			job := busLiveJob{
				fetch: pipeline.BindFetch(src, sink, busTestSpec()), sink: sink, store: store,
				notifier: &captureBusArrivalNotifier{}, now: time.Now,
			}

			if err := job.runCity(context.Background(), "Taipei"); !errors.Is(err, ackErr) {
				t.Fatalf("runCity error = %v, want %v", err, ackErr)
			}
			if len(src.acked) != 2 {
				t.Fatalf("Ack attempts = %v, want both independent feeds", src.acked)
			}
			for _, key := range []string{shared.BusETARawKey("Taipei"), shared.BusPositionRawKey("Taipei")} {
				if sw := sink.setFor(key); sw == nil || sw.ttl != _busFeedCacheTTL {
					t.Fatalf("raw feed cache %s = %+v", key, sw)
				}
			}
		})
	}
}
