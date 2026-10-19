package mrt

import (
	"errors"
	"reflect"
	"testing"
)

func TestMRTContractFirstlastAcceptsLatestProviderClock(t *testing.T) {
	sink := &fakeLoadSink{}
	body := `[{"StationID":"BL09","LineID":"BL","DestinationStaionID":"BL01","FirstTrainTime":"09:59","LastTrainTime":"29:59","ServiceDay":{"Monday":true}}]`
	if err := LoadFirstlast(t.Context(), decodeInto(body), sink, "TRTC"); err != nil {
		t.Fatal(err)
	}
	want := []any{"BL09", "BL", "", "BL01", "", "09:59", "29:59", uint8(1), "TRTC"}
	if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 || !reflect.DeepEqual(sink.calls[0].rows[0], want) {
		t.Fatalf("latest provider clock rows = %#v, want %#v", sink.calls, want)
	}
}

func TestMRTContractInvalidClockNeverReplacesFirstlastPartition(t *testing.T) {
	for _, clock := range []string{"39:00", "29:69", "29:60", "30:59"} {
		t.Run(clock, func(t *testing.T) {
			sink := &fakeLoadSink{}
			body := `[{"StationID":"BL09","LineID":"BL","DestinationStaionID":"BL01","FirstTrainTime":"` + clock + `","LastTrainTime":"29:59","ServiceDay":{"Monday":true}}]`
			err := LoadFirstlast(t.Context(), decodeInto(body), sink, "TRTC")
			if err == nil || !errMentions(err, "FirstTrainTime") {
				t.Fatalf("invalid provider clock error = %v, want FirstTrainTime rejection", err)
			}
			if len(sink.calls) != 0 {
				t.Fatal("invalid provider clock reached partition replacement")
			}
		})
	}
}

func TestMRTContractValidFareCannotHideZeroTicketType(t *testing.T) {
	sink := &fakeLoadSink{}
	body := `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":5,"Fares":[{"TicketType":1,"FareClass":1,"Price":20},{"TicketType":0,"FareClass":2,"Price":10}]}]`
	err := LoadJourneyMatrix(t.Context(), decodeInto(body), sink, "TRTC")
	if err == nil || !errMentions(err, "TicketType") {
		t.Fatalf("zero ticket type alongside valid fare error = %v, want TicketType rejection", err)
	}
	if len(sink.calls) != 0 {
		t.Fatal("invalid extra fare reached matrix persistence")
	}
}

func TestMRTContractJourneyMatrixKeepsZeroFare(t *testing.T) {
	sink := &fakeLoadSink{}
	body := `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":5,"Fares":[{"TicketType":1,"FareClass":1,"Price":0},{"TicketType":1,"FareClass":2,"Price":10}]}]`
	if err := LoadJourneyMatrix(t.Context(), decodeInto(body), sink, "TRTC"); err != nil {
		t.Fatal(err)
	}
	want := []any{"TRTC-BL01-BL02", "BL01", "BL02", "TRTC", 5, 0, 10}
	if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 || !reflect.DeepEqual(sink.calls[0].rows[0], want) {
		t.Fatalf("zero fare persistence rows = %#v, want %#v", sink.calls, want)
	}
}

func TestMRTContractInvalidTravelSegmentStopsBeforeTransferRead(t *testing.T) {
	for _, tc := range []struct {
		name, invalid, field string
	}{
		{name: "zero run time with positive stop", invalid: `{"FromStationID":"B","ToStationID":"C","RunTime":0,"StopTime":60}`, field: "RunTime"},
		{name: "negative stop time after valid run", invalid: `{"FromStationID":"B","ToStationID":"C","RunTime":90,"StopTime":-1}`, field: "StopTime"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			transferFailure := errors.New("transfer dataset must not be requested for invalid travel data")
			src := &fakeLoadSource{
				json: map[string][]byte{"metro_s2straveltime|TRTC": []byte(`[{"TravelTimes":[{"FromStationID":"A","ToStationID":"B","RunTime":90,"StopTime":20},` + tc.invalid + `]}]`)},
				errs: map[string]error{"metro_linetransfer|TRTC": transferFailure},
			}
			sink := &fakeLoadSink{}
			err := LoadTrtcTravelTime(t.Context(), src, sink, "TRTC")
			if err == nil || !errMentions(err, tc.field) || errors.Is(err, transferFailure) {
				t.Fatalf("invalid travel data error = %v, want %s validation before transfer fetch", err, tc.field)
			}
			if !reflect.DeepEqual(src.calls, []string{"metro_s2straveltime|TRTC"}) || len(sink.calls) != 0 {
				t.Fatalf("invalid graph caused source calls %#v and sink calls %#v", src.calls, sink.calls)
			}
		})
	}
}

func TestMRTContractPublicTravelLoadUsesEveryLineAndRoundedMinutes(t *testing.T) {
	src := &fakeLoadSource{json: map[string][]byte{
		"metro_s2straveltime|TRTC": []byte(`[
			{"TravelTimes":[{"FromStationID":"A","ToStationID":"B","RunTime":149,"StopTime":0}]},
			{"TravelTimes":[{"FromStationID":"B","ToStationID":"C","RunTime":1,"StopTime":0}]}
		]`),
		"metro_linetransfer|TRTC": []byte(`[]`),
	}}
	sink := &fakeLoadSink{}
	if err := LoadTrtcTravelTime(t.Context(), src, sink, "TRTC"); err != nil {
		t.Fatal(err)
	}
	if len(sink.calls) != 1 || sink.calls[0].spec.Key != "mrt_traveltime" {
		t.Fatalf("travel persistence calls = %#v", sink.calls)
	}
	want := [][]any{
		{int64(2), "A", "B", "TRTC"}, {int64(3), "A", "C", "TRTC"},
		{int64(2), "B", "A", "TRTC"}, {int64(1), "B", "C", "TRTC"},
		{int64(3), "C", "A", "TRTC"}, {int64(1), "C", "B", "TRTC"},
	}
	if !reflect.DeepEqual(sink.calls[0].rows, want) {
		t.Fatalf("travel rows = %#v, want %#v", sink.calls[0].rows, want)
	}
}

func TestMRTContractPublicTravelLoadAcceptsMaximumStoredMinute(t *testing.T) {
	src := &fakeLoadSource{json: map[string][]byte{
		"metro_s2straveltime|TRTC": []byte(`[{"TravelTimes":[{"FromStationID":"C","ToStationID":"D","RunTime":60,"StopTime":0}]}]`),
		"metro_linetransfer|TRTC":  []byte(`[{"FromStationID":"A","ToStationID":"B","TransferTime":2147483647}]`),
	}}
	sink := &fakeLoadSink{}
	if err := LoadTrtcTravelTime(t.Context(), src, sink, "TRTC"); err != nil {
		t.Fatal(err)
	}
	want := [][]any{
		{int64(1), "C", "D", "TRTC"}, {int64(1), "D", "C", "TRTC"},
		{int64(2147483647), "A", "B", "TRTC"}, {int64(2147483647), "B", "A", "TRTC"},
	}
	if len(sink.calls) != 1 || !reflect.DeepEqual(sink.calls[0].rows, want) {
		t.Fatalf("maximum-minute and disconnected-component rows = %#v, want %#v", sink.calls, want)
	}
}
