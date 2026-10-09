package mrt

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestLoadMrtStationsRejectsMalformedOrInvalidElement(t *testing.T) {
	tests := []struct {
		name string
		body string
		want string
	}{
		{
			name: "malformed later element",
			body: `[{"StationID":"BL12","StationPosition":{"PositionLon":121.6,"PositionLat":25.05}}, {"StationID":]`,
			want: "element 1",
		},
		{
			name: "missing station identity",
			body: `[{"StationPosition":{"PositionLon":121.6,"PositionLat":25.05}}]`,
			want: "StationID",
		},
		{
			name: "invalid position",
			body: `[{"StationID":"BL12","StationPosition":{"PositionLon":181,"PositionLat":25.05}}]`,
			want: "position",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := LoadStations(context.Background(), decodeInto(tt.body), sink, "TRTC")
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("LoadStations error = %v, want %q", err, tt.want)
			}
			if len(sink.calls) != 0 {
				t.Fatalf("copyUpsert calls = %d, want no write", len(sink.calls))
			}
		})
	}
}

func TestLoadMrtFirstlastRejectsInvalidIdentityOrTime(t *testing.T) {
	tests := []struct {
		name string
		body string
		want string
	}{
		{
			name: "missing destination",
			body: `[{"StationID":"BL12","LineID":"BL","FirstTrainTime":"06:00","LastTrainTime":"23:30"}]`,
			want: "DestinationStaionID",
		},
		{
			name: "invalid first train time",
			body: `[{"StationID":"BL12","LineID":"BL","DestinationStaionID":"BL01","FirstTrainTime":"midnight","LastTrainTime":"23:30"}]`,
			want: "FirstTrainTime",
		},
		{
			name: "invalid last train time",
			body: `[{"StationID":"BL12","LineID":"BL","DestinationStaionID":"BL01","FirstTrainTime":"06:00","LastTrainTime":"30:00"}]`,
			want: "LastTrainTime",
		},
		{
			name: "no service day",
			body: `[{"StationID":"BL12","LineID":"BL","DestinationStaionID":"BL01","FirstTrainTime":"06:00","LastTrainTime":"23:30","ServiceDay":{}}]`,
			want: "ServiceDay",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := LoadFirstlast(context.Background(), decodeInto(tt.body), sink, "TRTC")
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("LoadFirstlast error = %v, want %q", err, tt.want)
			}
			if len(sink.calls) != 0 {
				t.Fatalf("copyUpsert calls = %d, want no partition replacement", len(sink.calls))
			}
		})
	}
}

func TestLoadMrtFirstlastValidEmptyReplacesPartition(t *testing.T) {
	sink := &fakeLoadSink{}
	if err := LoadFirstlast(context.Background(), decodeInto(`[]`), sink, "TRTC"); err != nil {
		t.Fatalf("LoadFirstlast: %v", err)
	}
	if len(sink.calls) != 1 {
		t.Fatalf("copyUpsert calls = %d, want one atomic empty replacement", len(sink.calls))
	}
	if len(sink.calls[0].rows) != 0 || len(sink.calls[0].spec.PreExec) != 1 {
		t.Fatalf("empty replacement = %+v, want zero rows plus partition delete", sink.calls[0])
	}
}

func TestLoadMrtFirstlastDuplicatePolicyUsesCompleteTieBreaker(t *testing.T) {
	sink := &fakeLoadSink{}
	body := `[
		{"StationID":"BL12","LineID":"BL","TripHeadSign":"往頂埔","DestinationStaionID":"BL01","DestinationStationName":{"Zh_tw":"頂埔"},"FirstTrainTime":"06:00","LastTrainTime":"23:30","ServiceDay":{"Monday":true}},
		{"StationID":"BL12","LineID":"BL","TripHeadSign":"往南港展覽館","DestinationStaionID":"BL01","DestinationStationName":{"Zh_tw":"南港展覽館"},"FirstTrainTime":"06:00","LastTrainTime":"23:30","ServiceDay":{"Monday":true}}
	]`
	if err := LoadFirstlast(context.Background(), decodeInto(body), sink, "TRTC"); err != nil {
		t.Fatalf("LoadFirstlast: %v", err)
	}
	if len(sink.calls) != 1 {
		t.Fatalf("calls = %d, want one", len(sink.calls))
	}
	const want = "ORDER BY id, lid, dsid, mask, sys, ft, lt, dsname, sign"
	if !strings.Contains(sink.calls[0].spec.InsertSQL, want) {
		t.Fatalf("first-last duplicate policy lacks complete deterministic tie-breaker %q:\n%s", want, sink.calls[0].spec.InsertSQL)
	}
}

func TestLoadMrtJourneyMatrixRejectsInvalidIdentityOrTravelTime(t *testing.T) {
	tests := []struct {
		name string
		body string
		want string
	}{
		{
			name: "missing origin",
			body: `[{"DestinationStationID":"BL02","TravelTime":5}]`,
			want: "OriginStationID",
		},
		{
			name: "negative travel time",
			body: `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":-1}]`,
			want: "TravelTime",
		},
		{
			name: "fractional travel time",
			body: `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":1.5}]`,
			want: "TravelTime",
		},
		{
			name: "precision unsafe travel time",
			body: `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":9007199254740993,"Fares":[{"TicketType":1,"Price":20}]}]`,
			want: "TravelTime",
		},
		{
			name: "PostgreSQL integer overflow",
			body: `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":2147483648,"Fares":[{"TicketType":1,"Price":20}]}]`,
			want: "TravelTime",
		},
		{
			name: "tiny positive exponent",
			body: `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":1e-1000,"Fares":[{"TicketType":1,"Price":20}]}]`,
			want: "TravelTime",
		},
		{
			name: "missing adult fare",
			body: `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":5,"Fares":[{"TicketType":2,"Price":10}]}]`,
			want: "TicketType 1",
		},
		{
			name: "empty fares",
			body: `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":5,"Fares":[]}]`,
			want: "TicketType 1",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var err error
			func() {
				defer func() {
					if recovered := recover(); recovered != nil {
						t.Fatalf("LoadJourneyMatrix panicked before returning validation error: %v", recovered)
					}
				}()
				err = LoadJourneyMatrix(context.Background(), decodeInto(tt.body), &fakeLoadSink{}, "TRTC")
			}()
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("LoadJourneyMatrix error = %v, want %q", err, tt.want)
			}
		})
	}
}

func TestLoadMrtTravelTimeRejectsInvalidSegment(t *testing.T) {
	src := &fakeLoadSource{
		json: map[string][]byte{
			"metro_s2straveltime|TRTC": []byte(`[{"TravelTimes":[{"FromStationID":"","ToStationID":"BL02","RunTime":90,"StopTime":20}]}]`),
			"metro_linetransfer|TRTC":  []byte(`[]`),
		},
		fetched: time.Now(),
	}
	var err error
	func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				t.Fatalf("LoadTrtcTravelTime panicked before returning validation error: %v", recovered)
			}
		}()
		err = LoadTrtcTravelTime(context.Background(), src, &fakeLoadSink{}, "TRTC")
	}()
	if err == nil || !errMentions(err, "FromStationID") {
		t.Fatalf("LoadTrtcTravelTime error = %v, want FromStationID validation error", err)
	}
}

func TestLoadMrtTravelTimeRejectsFractionalDuration(t *testing.T) {
	tests := []struct {
		name     string
		s2s      string
		transfer string
		want     string
	}{
		{
			name:     "run time",
			s2s:      `[{"TravelTimes":[{"FromStationID":"BL01","ToStationID":"BL02","RunTime":90.5,"StopTime":20}]}]`,
			transfer: `[]`,
			want:     "RunTime",
		},
		{
			name:     "stop time",
			s2s:      `[{"TravelTimes":[{"FromStationID":"BL01","ToStationID":"BL02","RunTime":90,"StopTime":20.5}]}]`,
			transfer: `[]`,
			want:     "StopTime",
		},
		{
			name:     "transfer time",
			s2s:      `[]`,
			transfer: `[{"FromStationID":"BL01","ToStationID":"R01","TransferTime":3.5}]`,
			want:     "TransferTime",
		},
		{
			name:     "zero transfer time",
			s2s:      `[]`,
			transfer: `[{"FromStationID":"BL01","ToStationID":"R01","TransferTime":0}]`,
			want:     "TransferTime",
		},
		{
			name:     "precision unsafe run time",
			s2s:      `[{"TravelTimes":[{"FromStationID":"BL01","ToStationID":"BL02","RunTime":9007199254740993,"StopTime":20}]}]`,
			transfer: `[]`,
			want:     "RunTime",
		},
		{
			name:     "tiny positive stop time",
			s2s:      `[{"TravelTimes":[{"FromStationID":"BL01","ToStationID":"BL02","RunTime":90,"StopTime":1e-1000}]}]`,
			transfer: `[]`,
			want:     "StopTime",
		},
		{
			name:     "transfer duration exceeds safe bound",
			s2s:      `[]`,
			transfer: `[{"FromStationID":"BL01","ToStationID":"R01","TransferTime":2147483648}]`,
			want:     "TransferTime",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := &fakeLoadSource{
				json: map[string][]byte{
					"metro_s2straveltime|TRTC": []byte(tt.s2s),
					"metro_linetransfer|TRTC":  []byte(tt.transfer),
				},
				fetched: time.Now(),
			}
			err := LoadTrtcTravelTime(context.Background(), src, &fakeLoadSink{}, "TRTC")
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("LoadTrtcTravelTime error = %v, want whole-unit %s validation error", err, tt.want)
			}
		})
	}
}

func TestLoadMrtJourneyMatrixAcceptsExactWholeExponent(t *testing.T) {
	sink := &fakeLoadSink{}
	body := `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":1e3,"Fares":[{"TicketType":1,"Price":20}]}]`
	if err := LoadJourneyMatrix(context.Background(), decodeInto(body), sink, "TRTC"); err != nil {
		t.Fatalf("LoadJourneyMatrix: %v", err)
	}
	if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 || sink.calls[0].rows[0][4] != 1000 {
		t.Fatalf("exact exponent rows = %+v, want TravelTime 1000", sink.calls)
	}
}

func TestLoadMrtTravelTimeRejectsComputedPostgresIntegerOverflow(t *testing.T) {
	src := &fakeLoadSource{
		json: map[string][]byte{
			"metro_s2straveltime|TRTC": []byte(`[{"TravelTimes":[{"FromStationID":"C","ToStationID":"D","RunTime":60,"StopTime":0}]}]`),
			"metro_linetransfer|TRTC": []byte(`[
				{"FromStationID":"A","ToStationID":"B","TransferTime":2147483647},
				{"FromStationID":"B","ToStationID":"C","TransferTime":2147483647}
			]`),
		},
		fetched: time.Now(),
	}
	err := LoadTrtcTravelTime(context.Background(), src, &fakeLoadSink{}, "TRTC")
	if err == nil || !errMentions(err, "PostgreSQL integer") {
		t.Fatalf("LoadTrtcTravelTime error = %v, want computed target overflow rejection", err)
	}
}

func TestDecodeLoadArrayRejectsTrailingJSON(t *testing.T) {
	_, err := pipeline.DecodeLoadArray[map[string]any](json.NewDecoder(strings.NewReader(`[] {}`)), "probe", nil)
	if err == nil || !errMentions(err, "trailing") {
		t.Fatalf("pipeline.DecodeLoadArray error = %v, want trailing JSON error", err)
	}
}

func TestLoadMrtDuplicatePolicies(t *testing.T) {
	t.Run("station identical dedupe and divergent reject", func(t *testing.T) {
		station := `{"StationID":"BL12","StationName":{"Zh_tw":"站"},"StationPosition":{"PositionLon":121.6,"PositionLat":25.05}}`
		sink := &fakeLoadSink{}
		if err := LoadStations(context.Background(), decodeInto(`[`+station+`,`+station+`]`), sink, "TRTC"); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"StationID":"BL12","StationName":{"Zh_tw":"另一站"},"StationPosition":{"PositionLon":121.6,"PositionLat":25.05}}`
		err := LoadStations(context.Background(), decodeInto(`[`+station+`,`+other+`]`), &fakeLoadSink{}, "TRTC")
		if err == nil || !errMentions(err, "duplicate station") {
			t.Fatalf("divergent error = %v", err)
		}
	})
	t.Run("journey identical dedupe and divergent reject", func(t *testing.T) {
		fare := `{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":5,"Fares":[{"TicketType":1,"Price":20}]}`
		sink := &fakeLoadSink{}
		if err := LoadJourneyMatrix(context.Background(), decodeInto(`[`+fare+`,`+fare+`]`), sink, "TRTC"); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":6,"Fares":[{"TicketType":1,"Price":20}]}`
		err := LoadJourneyMatrix(context.Background(), decodeInto(`[`+fare+`,`+other+`]`), &fakeLoadSink{}, "TRTC")
		if err == nil || !errMentions(err, "duplicate OD") {
			t.Fatalf("divergent error = %v", err)
		}
	})
	// A conflicting price on the full (全票) class is a price users see, so it
	// still rejects.
	t.Run("journey divergent duplicate adult fare rejects", func(t *testing.T) {
		body := `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":5,"Fares":[{"TicketType":1,"FareClass":1,"Price":20},{"TicketType":1,"FareClass":1,"Price":25}]}]`
		err := LoadJourneyMatrix(context.Background(), decodeInto(body), &fakeLoadSink{}, "TRTC")
		if err == nil || !errMentions(err, "duplicate TicketType") {
			t.Fatalf("divergent adult fare error = %v", err)
		}
	})
	// Only the full and half classes are read, so a conflict on any other class
	// disputes a value the loader discards. Rejecting the system's whole matrix
	// over it took TRTC's fares offline; it must load.
	t.Run("journey divergent duplicate unread fare class loads", func(t *testing.T) {
		body := `[{"OriginStationID":"BL01","DestinationStationID":"BL02","TravelTime":5,"Fares":[{"TicketType":1,"FareClass":1,"Price":20},{"TicketType":1,"FareClass":3,"Price":15},{"TicketType":1,"FareClass":3,"Price":18}]}]`
		sink := &fakeLoadSink{}
		if err := LoadJourneyMatrix(context.Background(), decodeInto(body), sink, "TRTC"); err != nil {
			t.Fatalf("divergent unread fare class error = %v, want the matrix to load", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("rows = %+v, want the OD pair written through", sink.calls)
		}
	})
}

func TestLoadMrtStationsConflictRefreshesBikeAllowance(t *testing.T) {
	sink := &fakeLoadSink{}
	body := `[{"StationID":"BL12","StationPosition":{"PositionLon":121.6,"PositionLat":25.05},"BikeAllowOnHoliday":true}]`
	if err := LoadStations(context.Background(), decodeInto(body), sink, "TRTC"); err != nil {
		t.Fatalf("LoadStations: %v", err)
	}
	if len(sink.calls) != 1 || !strings.Contains(sink.calls[0].spec.InsertSQL, "bikeallowonholiday = EXCLUDED.bikeallowonholiday") {
		t.Fatalf("MRT station conflict SQL does not refresh bikeallowonholiday:\n%s", sink.calls[0].spec.InsertSQL)
	}
}

// KRTC publishes rows with an empty FirstTrainTime for lines it has no window
// for. ServiceWindows already skips a row it cannot parse, so an empty value
// is absent data, not a defect; rejecting it discarded the whole system.
func TestLoadMrtFirstlastAcceptsEmptyTrainTime(t *testing.T) {
	sink := &fakeLoadSink{}
	err := LoadFirstlast(context.Background(), decodeInto(
		`[{"StationID":"R10","LineID":"R","DestinationStaionID":"R24","FirstTrainTime":"","LastTrainTime":"","ServiceDay":{"Monday":true}}]`,
	), sink, "KRTC")
	if err != nil {
		t.Fatalf("LoadFirstlast error = %v, want an empty train time to load", err)
	}
	if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
		t.Fatalf("copyUpsert calls = %+v, want the row written through", sink.calls)
	}
}
