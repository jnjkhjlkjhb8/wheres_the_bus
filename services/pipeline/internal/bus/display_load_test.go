package bus

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

type displayStopSink struct {
	spec pipeline.CopyUpsertSpec
	rows [][]any
	err  error
}

func (sink *displayStopSink) CopyUpsert(_ context.Context, spec pipeline.CopyUpsertSpec, rows [][]any) error {
	sink.spec, sink.rows = spec, rows
	return sink.err
}

func TestDisplayStopsValidateBeforePartitionReplacement(t *testing.T) {
	valid := `[{"RouteUID":"TPE10132","Direction":1,"Stops":[{"StopUID":"S1","StopName":{"Zh_tw":"甲站"},"StopSequence":1,"StationID":"ST1"}]}]`
	for _, test := range []struct {
		city, body string
	}{
		{"", valid}, {"unknown", valid}, {"Taipei", "null"},
		{"Taipei", strings.Replace(valid, "TPE10132", "KHH10132", 1)}, {"Taipei", "[{"},
	} {
		sink := &displayStopSink{}
		if err := LoadDisplayStops(context.Background(), json.NewDecoder(strings.NewReader(test.body)), sink, test.city); err == nil {
			t.Fatalf("invalid %s/%s succeeded", test.city, test.body)
		}
		if sink.rows != nil {
			t.Fatal("invalid source reached partition replacement")
		}
	}
	for _, failure := range []error{nil, errors.New("COPY failed")} {
		sink := &displayStopSink{err: failure}
		err := LoadDisplayStops(context.Background(), json.NewDecoder(strings.NewReader(valid)), sink, "Taipei")
		if !errors.Is(err, failure) {
			t.Fatalf("sink error = %v", err)
		}
		want := [][]any{{"TPE10132", int16(1), "S1", int16(1), "ST1", "甲站"}}
		if !reflect.DeepEqual(sink.rows, want) || sink.spec.TempTable != "temp_bus_display_stop" {
			t.Fatalf("display replacement = %#v, %+v", sink.rows, sink.spec)
		}
		if len(sink.spec.PreExec) != 1 || !reflect.DeepEqual(sink.spec.PreExec[0].Args, []any{"TPE%"}) {
			t.Fatalf("replacement scope = %+v", sink.spec.PreExec)
		}
	}
	if err := LoadDisplayStops(context.Background(), json.NewDecoder(strings.NewReader("[]")), nil, "Taipei"); err != nil {
		t.Fatalf("empty display feed = %v", err)
	}
}
