package mrt

import (
	"context"
	"encoding/json"
	"testing"
)

func TestExactDurationIntegerBoundaries(t *testing.T) {
	for _, test := range []struct {
		number   string
		optional bool
		maximum  int64
		want     int64
		fail     bool
	}{
		{"", true, 10, 0, false}, {"", false, 10, 0, true},
		{"bad", false, 10, 0, true}, {"-1", false, 10, 0, true},
		{"1.5", false, 10, 0, true}, {"9223372036854775808", false, 10, 0, true},
		{"11", false, 10, 0, true}, {"10", false, 10, 10, false},
		{"0", false, 10, 0, false}, {"1e1", false, 10, 10, false},
	} {
		t.Run(test.number, func(t *testing.T) {
			got, err := nonNegativeJSONInteger(json.Number(test.number), "duration", test.optional, test.maximum)
			if (err != nil) != test.fail || got != test.want {
				t.Fatalf("got %d, %v; want %d, error=%v", got, err, test.want, test.fail)
			}
		})
	}
}

func TestAdjacencyLoaderValidatesEdgesBeforeWriting(t *testing.T) {
	for _, test := range []struct {
		name, body, system string
		fail               bool
		rows               int
	}{
		{"empty system", `[]`, " ", true, 0},
		{"bad JSON", `[{`, "TRTC", true, 0},
		{"missing line", `[{}]`, "TRTC", true, 0},
		{"missing from", `[{"LineID":"BL","TravelTimes":[{"ToStationID":"B"}]}]`, "TRTC", true, 0},
		{"missing to", `[{"LineID":"BL","TravelTimes":[{"FromStationID":"A"}]}]`, "TRTC", true, 0},
		{"no edges", `[]`, "TRTC", false, 0},
		{"bidirectional", `[{"LineID":"BL","TravelTimes":[{"FromStationID":"A","ToStationID":"B"}]}]`, "TRTC", false, 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := LoadAdjacency(context.Background(), decodeInto(test.body), sink, test.system)
			if (err != nil) != test.fail {
				t.Fatalf("error = %v, want failure=%v", err, test.fail)
			}
			if test.rows == 0 {
				if len(sink.calls) != 0 {
					t.Fatal("invalid/empty edges reached sink")
				}
				return
			}
			if len(sink.calls) != 1 || len(sink.calls[0].rows) != test.rows {
				t.Fatalf("calls = %#v", sink.calls)
			}
			for _, row := range sink.calls[0].rows {
				if row[0] != "TRTC" || row[1] != "BL" {
					t.Fatalf("edge scope = %#v", row)
				}
			}
		})
	}
}
