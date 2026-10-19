package rail

import (
	"context"
	"errors"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestRailShapeLoaderPreservesSystemAndSkipsInvalidOrConflictingRows(t *testing.T) {
	for _, mode := range []string{"tra", "thsr", "metro"} {
		t.Run(mode, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := LoadShape(mode)(context.Background(), decodeInto(`[
				{"LineID":"","Geometry":"LINESTRING(121 25,122 26)"},
				{"LineID":"bad","Geometry":"POINT(121 25)"},
				{"LineID":" R1 ","LineName":{"Zh_tw":"紅線","En":"Red"},"Geometry":"LINESTRING(121 25,122 26)","UpdateTime":"2026-10-10T01:00:00Z"},
				{"LineID":"R1","Geometry":"LINESTRING(123 27,124 28)"},
				{"LineID":"R2","Geometry":"MULTILINESTRING((121 25,122 26))"}
			]`), sink, "TRTC")
			if err != nil {
				t.Fatal(err)
			}
			if len(sink.calls) != 1 || len(sink.calls[0].rows) != 2 {
				t.Fatalf("calls = %#v, want two valid unique rows", sink.calls)
			}
			call := sink.calls[0]
			wantSystem := ""
			if mode == "metro" {
				wantSystem = "TRTC"
			}
			row := call.rows[0]
			if row[0] != mode || row[1] != wantSystem || row[2] != "R1" || row[4] != "LINESTRING(121 25,122 26)" {
				t.Fatalf("first row = %#v", row)
			}
			if call.spec.PreExec[0].Args[0] != mode || call.spec.PreExec[0].Args[1] != wantSystem {
				t.Fatalf("replacement scope = %#v", call.spec.PreExec)
			}
		})
	}
}

type shapeErrorSink struct{ err error }

func (s shapeErrorSink) CopyUpsert(context.Context, pipeline.CopyUpsertSpec, [][]any) error {
	return s.err
}

func TestRailShapeLoaderRejectsMalformedInputAndPreservesSinkError(t *testing.T) {
	for _, body := range []string{`[]`, `[{"LineID":"invalid","Geometry":"broken"}]`} {
		sink := &fakeLoadSink{}
		if err := LoadShape("tra")(context.Background(), decodeInto(body), sink, ""); err != nil {
			t.Fatal(err)
		}
		if len(sink.calls) != 0 {
			t.Fatal("empty/invalid shapes reached sink")
		}
	}
	if err := LoadShape("thsr")(context.Background(), decodeInto(`[{"LineID":`), &fakeLoadSink{}, ""); err == nil {
		t.Fatal("malformed input succeeded")
	}
	want := errors.New("write denied")
	err := LoadShape("tra")(context.Background(), decodeInto(`[{"LineID":"R1","Geometry":"LINESTRING(121 25,122 26)"}]`), shapeErrorSink{want}, "")
	if !errors.Is(err, want) {
		t.Fatalf("error = %v, want %v", err, want)
	}
}
