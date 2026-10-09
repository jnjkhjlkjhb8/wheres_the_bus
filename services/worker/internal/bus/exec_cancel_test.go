package bus

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

func TestBusWriterCancelsDuringExecWithoutAck(t *testing.T) {
	tests := []struct {
		name     string
		fixtures map[string][]byte
		run      func(context.Context, *fakeLiveSource, *captureLiveSink) error
	}{

		{name: "bus", fixtures: map[string][]byte{
			"bus_EstimatedTimeOfArrivalTaipei": []byte(`[]`),
			"bus_RealTimeByFrequencyTaipei":    []byte(`[]`),
		}, run: func(ctx context.Context, src *fakeLiveSource, sink *captureLiveSink) error {
			prefix := busmodel.CityPrefix["Taipei"]
			predict.StaticMapCache().Delete(prefix)
			t.Cleanup(func() { predict.StaticMapCache().Delete(prefix) })
			job := busLiveJob{
				fetch: pipeline.BindFetch(src, sink, busTestSpec()), sink: sink,
				store:    &fakeBusEtaStore{stops: []busmodel.StationMap{{StationUID: "S", SubRouteUID: "TPE1", StopUID: "STOP", StopSequence: 1}}},
				notifier: &captureBusArrivalNotifier{}, now: time.Now,
			}
			return job.runCity(ctx, "Taipei")
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			src := &fakeLiveSource{fixtures: test.fixtures}
			execStarted := false
			sink := &captureLiveSink{execHook: func() error {
				execStarted = true
				cancel()
				<-ctx.Done()
				return ctx.Err()
			}}
			err := test.run(ctx, src, sink)
			if !execStarted {
				t.Fatal("test did not cancel during Exec")
			}
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("writer error = %v, want context canceled", err)
			}
			if len(src.acked) != 0 {
				t.Fatalf("canceled Exec acknowledged TDX marker: %v", src.acked)
			}
			if len(sink.contexts) == 0 || sink.contexts[0] != ctx {
				t.Fatalf("pipeline contexts = %v, want job context", sink.contexts)
			}
		})
	}
}
