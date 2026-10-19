package mrt

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestMRTLoadsRequireSystemBeforeWriting(t *testing.T) {
	for _, load := range []func(context.Context, *fakeLoadSink) error{
		func(ctx context.Context, sink *fakeLoadSink) error {
			return LoadStations(ctx, decodeInto(`[]`), sink, " ")
		},
		func(ctx context.Context, sink *fakeLoadSink) error {
			return LoadFirstlast(ctx, decodeInto(`[]`), sink, " ")
		},
		func(ctx context.Context, sink *fakeLoadSink) error {
			return LoadJourneyMatrix(ctx, decodeInto(`[]`), sink, " ")
		},
	} {
		sink := &fakeLoadSink{}
		if err := load(context.Background(), sink); err == nil || !strings.Contains(err.Error(), "system is required") {
			t.Fatalf("missing system: %v", err)
		}
		if len(sink.calls) != 0 {
			t.Fatal("missing system reached sink")
		}
	}
}

func TestMRTInvalidIdentityAndFareCodesNeverReplaceRows(t *testing.T) {
	for _, body := range []string{
		`[{"LineID":"BL","DestinationStaionID":"BL01"}]`,
		`[{"StationID":"BL12","DestinationStaionID":"BL01"}]`,
	} {
		sink := &fakeLoadSink{}
		if err := LoadFirstlast(context.Background(), decodeInto(body), sink, "TRTC"); err == nil {
			t.Fatal("incomplete identity accepted")
		}
		if len(sink.calls) != 0 {
			t.Fatal("incomplete identity reached sink")
		}
	}
	for _, body := range []string{
		`[{"DestinationStationID":"BL02","Fares":[{"TicketType":1,"FareClass":1,"Price":20}]}]`,
		`[{"OriginStationID":"BL01","Fares":[{"TicketType":1,"FareClass":1,"Price":20}]}]`,
		`[{"OriginStationID":"BL01","DestinationStationID":"BL02","Fares":[{"TicketType":0,"FareClass":1,"Price":20}]}]`,
		`[{"OriginStationID":"BL01","DestinationStationID":"BL02","Fares":[{"TicketType":1,"FareClass":-1,"Price":20}]}]`,
		`[{"OriginStationID":"BL01","DestinationStationID":"BL02","Fares":[{"TicketType":1,"FareClass":1,"Price":-1}]}]`,
	} {
		sink := &fakeLoadSink{}
		if err := LoadJourneyMatrix(context.Background(), decodeInto(body), sink, "TRTC"); err == nil {
			t.Fatal("invalid fare accepted")
		}
		if len(sink.calls) != 0 {
			t.Fatal("invalid fare reached sink")
		}
	}
}

type rejectingTravelSink struct{ err error }

func (s rejectingTravelSink) CopyUpsert(context.Context, pipeline.CopyUpsertSpec, [][]any) error {
	return s.err
}

func TestMRTTravelRowsPreserveEmptyOverflowAndPersistenceErrors(t *testing.T) {
	ctx := context.Background()
	sink := &fakeLoadSink{}
	if err := writeMRTTravelTimes(ctx, sink, "TRTC", []string{"BL01"}, [][]int64{{0}}); err != nil {
		t.Fatal(err)
	}
	if len(sink.calls) != 0 {
		t.Fatal("self-only graph wrote rows")
	}
	overflow := _maxPostgresInteger*60 + 60
	if err := writeMRTTravelTimes(ctx, sink, "TRTC", []string{"BL01", "BL02"}, [][]int64{{0, overflow}, {overflow, 0}}); err == nil {
		t.Fatal("overflowing duration accepted")
	}
	if len(sink.calls) != 0 {
		t.Fatal("overflowing graph wrote rows")
	}
	want := errors.New("database unavailable")
	if err := writeMRTTravelTimes(ctx, rejectingTravelSink{want}, "TRTC", []string{"BL01", "BL02"}, [][]int64{{0, 60}, {60, 0}}); !errors.Is(err, want) {
		t.Fatalf("sink error = %v", err)
	}
	if _, err := mrtJourneyRows([]mrtODFare{{TravelTime: "broken"}}, "TRTC"); err == nil {
		t.Fatal("corrupt travel duration staged")
	}
}
