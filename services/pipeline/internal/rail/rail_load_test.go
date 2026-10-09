package rail

import (
	"context"
	"encoding/json"
	"testing"
)

func validTraPresencePayload() map[string]any {
	return map[string]any{
		"DailyTrainInfo": map[string]any{
			"TrainNo": "123", "Direction": 0, "StartingStationID": "1000", "EndingStationID": "1001",
			"WheelchairFlag": 0, "PackageServiceFlag": 0, "DiningFlag": 0, "BikeFlag": 0,
			"BreastFeedingFlag": 0, "DailyFlag": 0, "ServiceAddedFlag": 0, "SuspendedFlag": 0,
		},
		"StopTimes": []any{map[string]any{
			"StopSequence": 1, "StationID": "1000", "ArrivalTime": "08:00", "DepartureTime": "08:01", "SuspendedFlag": 0,
		}},
	}
}

func validThsrPresencePayload() map[string]any {
	return map[string]any{
		"TrainDate": "2026-07-15",
		"DailyTrainInfo": map[string]any{
			"TrainNo": "0101", "Direction": 0, "StartingStationID": "0990", "EndingStationID": "1070", "Overnight": false,
		},
		"StopTimes": []any{map[string]any{
			"StopSequence": 1, "StationID": "0990", "ArrivalTime": "08:00", "DepartureTime": "08:01",
		}},
	}
}

func TestLoadThsrStationRejectsMalformedElement(t *testing.T) {
	err := LoadThsrStation(context.Background(), decodeInto(`[
		{"StationID":"0990","StationCode":"NAK","LocationCityCode":"TPE","StationPosition":{"PositionLon":121.6,"PositionLat":25.05}},
		{"StationID":
	]`), &fakeLoadSink{}, "")
	if err == nil || !errMentions(err, "element 1") {
		t.Fatalf("LoadThsrStation error = %v, want wrapped element 1 decode error", err)
	}
}

func TestLoadRailTimetablesRejectInvalidTimeDateIdentityOrFlag(t *testing.T) {
	tests := []struct {
		name string
		load func(context.Context, *fakeLoadSink, string) error
		want string
	}{
		{
			name: "TRA invalid partition date",
			load: func(ctx context.Context, sink *fakeLoadSink, _ string) error {
				return LoadTraTimetable(ctx, decodeInto(`[]`), sink, "2026-02-30")
			},
			want: "date",
		},
		{
			name: "TRA missing train identity",
			load: func(ctx context.Context, sink *fakeLoadSink, _ string) error {
				return LoadTraTimetable(ctx, decodeInto(`[{"DailyTrainInfo":{"StartingStationID":"1000","EndingStationID":"1001"},"StopTimes":[{"StopSequence":1,"StationID":"1000","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]`), sink, "2026-07-15")
			},
			want: "TrainNo",
		},
		{
			name: "TRA invalid clock",
			load: func(ctx context.Context, sink *fakeLoadSink, _ string) error {
				return LoadTraTimetable(ctx, decodeInto(`[{"DailyTrainInfo":{"TrainNo":"123","Direction":0,"StartingStationID":"1000","EndingStationID":"1001","WheelchairFlag":0,"PackageServiceFlag":0,"DiningFlag":0,"BikeFlag":0,"BreastFeedingFlag":0,"DailyFlag":0,"ServiceAddedFlag":0,"SuspendedFlag":0},"StopTimes":[{"StopSequence":1,"StationID":"1000","ArrivalTime":"25:00","DepartureTime":"08:01","SuspendedFlag":0}]}]`), sink, "2026-07-15")
			},
			want: "ArrivalTime",
		},
		{
			name: "TRA invalid boolean flag",
			load: func(ctx context.Context, sink *fakeLoadSink, _ string) error {
				return LoadTraTimetable(ctx, decodeInto(`[{"DailyTrainInfo":{"TrainNo":"123","Direction":0,"StartingStationID":"1000","EndingStationID":"1001","WheelchairFlag":2,"PackageServiceFlag":0,"DiningFlag":0,"BikeFlag":0,"BreastFeedingFlag":0,"DailyFlag":0,"ServiceAddedFlag":0,"SuspendedFlag":0},"StopTimes":[{"StopSequence":1,"StationID":"1000","ArrivalTime":"08:00","DepartureTime":"08:01","SuspendedFlag":0}]}]`), sink, "2026-07-15")
			},
			want: "WheelchairFlag",
		},
		{
			name: "THSR mismatched train date",
			load: func(ctx context.Context, sink *fakeLoadSink, _ string) error {
				return LoadThsrTimetable(ctx, decodeInto(`[{"TrainDate":"2026-07-16","DailyTrainInfo":{"TrainNo":"0101","StartingStationID":"0990","EndingStationID":"1070"},"StopTimes":[{"StopSequence":1,"StationID":"0990","ArrivalTime":"08:00","DepartureTime":"08:01"}]}]`), sink, "2026-07-15")
			},
			want: "TrainDate",
		},
		{
			name: "THSR missing stop identity",
			load: func(ctx context.Context, sink *fakeLoadSink, _ string) error {
				return LoadThsrTimetable(ctx, decodeInto(`[{"TrainDate":"2026-07-15","DailyTrainInfo":{"TrainNo":"0101","Direction":0,"StartingStationID":"0990","EndingStationID":"1070","Overnight":false},"StopTimes":[{"StopSequence":1,"ArrivalTime":"08:00","DepartureTime":"08:01"}]}]`), sink, "2026-07-15")
			},
			want: "StationID",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := tt.load(context.Background(), sink, tt.name)
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("load error = %v, want %q", err, tt.want)
			}
			if len(sink.calls) != 0 {
				t.Fatalf("copyUpsert calls = %d, want no write", len(sink.calls))
			}
		})
	}
}

func TestLoadRailTimetablesRequirePresenceOfScalarFields(t *testing.T) {
	traFields := []string{
		"Direction", "WheelchairFlag", "PackageServiceFlag", "DiningFlag", "BikeFlag",
		"BreastFeedingFlag", "DailyFlag", "ServiceAddedFlag", "SuspendedFlag",
	}
	for _, field := range traFields {
		t.Run("TRA missing "+field, func(t *testing.T) {
			payload := validTraPresencePayload()
			dailyTrainInfo, ok := payload["DailyTrainInfo"].(map[string]any)
			if !ok {
				t.Fatalf("DailyTrainInfo is not a map[string]any")
			}
			delete(dailyTrainInfo, field)
			body, err := json.Marshal([]any{payload})
			if err != nil {
				t.Fatal(err)
			}
			sink := &fakeLoadSink{}
			err = LoadTraTimetable(context.Background(), decodeInto(string(body)), sink, "2026-07-15")
			if err == nil || !errMentions(err, field) {
				t.Fatalf("LoadTraTimetable error = %v, want missing %s", err, field)
			}
			if len(sink.calls) != 0 {
				t.Fatal("missing required TRA scalar reached sink")
			}
		})
	}

	t.Run("TRA missing stop SuspendedFlag", func(t *testing.T) {
		payload := validTraPresencePayload()
		stopTimes, ok := payload["StopTimes"].([]any)
		if !ok || len(stopTimes) == 0 {
			t.Fatalf("StopTimes is not a non-empty []any")
		}
		stop, ok := stopTimes[0].(map[string]any)
		if !ok {
			t.Fatalf("StopTimes[0] is not a map[string]any")
		}
		delete(stop, "SuspendedFlag")
		body, err := json.Marshal([]any{payload})
		if err != nil {
			t.Fatal(err)
		}
		sink := &fakeLoadSink{}
		err = LoadTraTimetable(context.Background(), decodeInto(string(body)), sink, "2026-07-15")
		if err == nil || !errMentions(err, "SuspendedFlag") {
			t.Fatalf("LoadTraTimetable error = %v, want missing stop SuspendedFlag", err)
		}
		if len(sink.calls) != 0 {
			t.Fatal("missing required TRA stop scalar reached sink")
		}
	})

	for _, field := range []string{"Direction", "Overnight"} {
		t.Run("THSR missing "+field, func(t *testing.T) {
			payload := validThsrPresencePayload()
			dailyTrainInfo, ok := payload["DailyTrainInfo"].(map[string]any)
			if !ok {
				t.Fatalf("DailyTrainInfo is not a map[string]any")
			}
			delete(dailyTrainInfo, field)
			body, err := json.Marshal([]any{payload})
			if err != nil {
				t.Fatal(err)
			}
			sink := &fakeLoadSink{}
			err = LoadThsrTimetable(context.Background(), decodeInto(string(body)), sink, "2026-07-15")
			if err == nil || !errMentions(err, field) {
				t.Fatalf("LoadThsrTimetable error = %v, want missing %s", err, field)
			}
			if len(sink.calls) != 0 {
				t.Fatal("missing required THSR scalar reached sink")
			}
		})
	}
}

func TestLoadRailTimetableValidEmptyReplacesDate(t *testing.T) {
	for _, tt := range []struct {
		name string
		load func(context.Context, *fakeLoadSink) error
	}{
		{"TRA", func(ctx context.Context, sink *fakeLoadSink) error {
			return LoadTraTimetable(ctx, decodeInto(`[]`), sink, "2026-07-15")
		}},
		{"THSR", func(ctx context.Context, sink *fakeLoadSink) error {
			return LoadThsrTimetable(ctx, decodeInto(`[]`), sink, "2026-07-15")
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			if err := tt.load(context.Background(), sink); err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(sink.calls) != 1 || len(sink.calls[0].rows) != 0 || len(sink.calls[0].spec.PreExec) != 1 {
				t.Fatalf("calls = %+v, want one zero-row date replacement", sink.calls)
			}
		})
	}
}

func TestLoadRailStationsRejectInvalidIdentityCityOrPosition(t *testing.T) {
	tests := []struct {
		name string
		load func(context.Context, *fakeLoadSink) error
		want string
	}{
		{
			name: "TRA missing station ID",
			load: func(ctx context.Context, sink *fakeLoadSink) error {
				return LoadTraStation(ctx, decodeInto(`[{"LocationCityCode":"TPE","StationPosition":{"PositionLon":121.5,"PositionLat":25.0}}]`), sink, "")
			},
			want: "StationID",
		},
		{
			name: "TRA unknown city",
			load: func(ctx context.Context, sink *fakeLoadSink) error {
				return LoadTraStation(ctx, decodeInto(`[{"StationID":"1000","LocationCityCode":"ZZZ","StationPosition":{"PositionLon":121.5,"PositionLat":25.0}}]`), sink, "")
			},
			want: "LocationCityCode",
		},
		{
			name: "THSR invalid position",
			load: func(ctx context.Context, sink *fakeLoadSink) error {
				return LoadThsrStation(ctx, decodeInto(`[{"StationID":"0990","StationCode":"NAK","LocationCityCode":"TPE","StationPosition":{"PositionLon":0,"PositionLat":0}}]`), sink, "")
			},
			want: "position",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := tt.load(context.Background(), sink)
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("load error = %v, want %q", err, tt.want)
			}
			if len(sink.calls) != 0 {
				t.Fatalf("copyUpsert calls = %d, want no write", len(sink.calls))
			}
		})
	}
}

func TestLoadRailFaresRejectInvalidIdentity(t *testing.T) {
	tests := []struct {
		name string
		load func(context.Context, *fakeLoadSink) error
		want string
	}{
		{
			name: "TRA missing origin",
			load: func(ctx context.Context, sink *fakeLoadSink) error {
				return LoadTraFare(ctx, decodeInto(`[{"DestinationStationID":"1001","Fares":[{"TicketType":"Adult","Price":40}]}]`), sink, "")
			},
			want: "OriginStationID",
		},
		{
			name: "TRA missing ticket type",
			load: func(ctx context.Context, sink *fakeLoadSink) error {
				return LoadTraFare(ctx, decodeInto(`[{"OriginStationID":"1000","DestinationStationID":"1001","Fares":[{"Price":40}]}]`), sink, "")
			},
			want: "TicketType",
		},
		{
			name: "THSR missing destination",
			load: func(ctx context.Context, sink *fakeLoadSink) error {
				return LoadThsrFare(ctx, decodeInto(`[{"OriginStationID":"0990","Fares":[{"TicketType":1,"FareClass":1,"CabinClass":1,"Price":40}]}]`), sink, "")
			},
			want: "DestinationStationID",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := tt.load(context.Background(), sink)
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("load error = %v, want %q", err, tt.want)
			}
			if len(sink.calls) != 0 {
				t.Fatalf("copyUpsert calls = %d, want no write", len(sink.calls))
			}
		})
	}
}

func TestLoadRailFareValidEmptyIsNoOp(t *testing.T) {
	for _, tt := range []struct {
		name string
		load func(context.Context, *fakeLoadSink) error
	}{
		{"TRA", func(ctx context.Context, sink *fakeLoadSink) error {
			return LoadTraFare(ctx, decodeInto(`[]`), sink, "")
		}},
		{"THSR", func(ctx context.Context, sink *fakeLoadSink) error {
			return LoadThsrFare(ctx, decodeInto(`[]`), sink, "")
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			if err := tt.load(context.Background(), sink); err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(sink.calls) != 0 {
				t.Fatalf("copyUpsert calls = %d, want additive empty no-op", len(sink.calls))
			}
		})
	}
}

func TestLoadRailDuplicatePolicies(t *testing.T) {
	t.Run("TRA station identical dedupe and divergent reject", func(t *testing.T) {
		station := `{"StationID":"1000","StationName":{"Zh_tw":"台北"},"LocationCityCode":"TPE","StationPosition":{"PositionLon":121.5,"PositionLat":25.0}}`
		sink := &fakeLoadSink{}
		if err := LoadTraStation(context.Background(), decodeInto(`[`+station+`,`+station+`]`), sink, ""); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"StationID":"1000","StationName":{"Zh_tw":"臺北"},"LocationCityCode":"TPE","StationPosition":{"PositionLon":121.5,"PositionLat":25.0}}`
		err := LoadTraStation(context.Background(), decodeInto(`[`+station+`,`+other+`]`), &fakeLoadSink{}, "")
		if err == nil || !errMentions(err, "duplicate station") {
			t.Fatalf("divergent error = %v", err)
		}
	})
	t.Run("THSR station identical dedupe and divergent reject", func(t *testing.T) {
		station := `{"StationID":"0990","StationCode":"0990","StationName":{"Zh_tw":"南港"},"LocationCityCode":"TPE","StationPosition":{"PositionLon":121.6,"PositionLat":25.05}}`
		sink := &fakeLoadSink{}
		if err := LoadThsrStation(context.Background(), decodeInto(`[`+station+`,`+station+`]`), sink, ""); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"StationID":"0990","StationCode":"0990","StationName":{"Zh_tw":"南港站"},"LocationCityCode":"TPE","StationPosition":{"PositionLon":121.6,"PositionLat":25.05}}`
		err := LoadThsrStation(context.Background(), decodeInto(`[`+station+`,`+other+`]`), &fakeLoadSink{}, "")
		if err == nil || !errMentions(err, "duplicate station") {
			t.Fatalf("divergent error = %v", err)
		}
	})
	t.Run("TRA fare identical dedupe and divergent reject", func(t *testing.T) {
		fare := `{"OriginStationID":"1000","DestinationStationID":"1001","Fares":[{"TicketType":"Adult","Price":40},{"TicketType":"Adult","Price":40}]}`
		sink := &fakeLoadSink{}
		if err := LoadTraFare(context.Background(), decodeInto(`[`+fare+`]`), sink, ""); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"OriginStationID":"1000","DestinationStationID":"1001","Fares":[{"TicketType":"Adult","Price":41}]}`
		err := LoadTraFare(context.Background(), decodeInto(`[`+fare+`,`+other+`]`), &fakeLoadSink{}, "")
		if err == nil || !errMentions(err, "duplicate fare") {
			t.Fatalf("divergent error = %v", err)
		}
	})
	t.Run("THSR fare identical dedupe and divergent reject", func(t *testing.T) {
		fare := `{"OriginStationID":"0990","DestinationStationID":"1070","Fares":[{"TicketType":1,"FareClass":1,"CabinClass":1,"Price":40},{"TicketType":1,"FareClass":1,"CabinClass":1,"Price":40}]}`
		sink := &fakeLoadSink{}
		if err := LoadThsrFare(context.Background(), decodeInto(`[`+fare+`]`), sink, ""); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"OriginStationID":"0990","DestinationStationID":"1070","Fares":[{"TicketType":1,"FareClass":1,"CabinClass":1,"Price":41}]}`
		err := LoadThsrFare(context.Background(), decodeInto(`[`+fare+`,`+other+`]`), &fakeLoadSink{}, "")
		if err == nil || !errMentions(err, "duplicate fare") {
			t.Fatalf("divergent error = %v", err)
		}
	})
	t.Run("TRA timetable identical dedupe and divergent reject", func(t *testing.T) {
		row := `{"DailyTrainInfo":{"TrainNo":"123","Direction":0,"StartingStationID":"1000","EndingStationID":"1001","WheelchairFlag":0,"PackageServiceFlag":0,"DiningFlag":0,"BikeFlag":0,"BreastFeedingFlag":0,"DailyFlag":0,"ServiceAddedFlag":0,"SuspendedFlag":0},"StopTimes":[{"StopSequence":1,"StationID":"1000","ArrivalTime":"08:00","DepartureTime":"08:01","SuspendedFlag":0}]}`
		sink := &fakeLoadSink{}
		if err := LoadTraTimetable(context.Background(), decodeInto(`[`+row+`,`+row+`]`), sink, "2026-07-15"); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"DailyTrainInfo":{"TrainNo":"123","Direction":0,"StartingStationID":"1000","EndingStationID":"1001","WheelchairFlag":0,"PackageServiceFlag":0,"DiningFlag":0,"BikeFlag":0,"BreastFeedingFlag":0,"DailyFlag":0,"ServiceAddedFlag":0,"SuspendedFlag":0},"StopTimes":[{"StopSequence":1,"StationID":"1000","ArrivalTime":"08:02","DepartureTime":"08:03","SuspendedFlag":0}]}`
		err := LoadTraTimetable(context.Background(), decodeInto(`[`+row+`,`+other+`]`), &fakeLoadSink{}, "2026-07-15")
		if err == nil || !errMentions(err, "duplicate timetable") {
			t.Fatalf("divergent error = %v", err)
		}
	})
	t.Run("THSR timetable identical dedupe and divergent reject", func(t *testing.T) {
		row := `{"TrainDate":"2026-07-15","DailyTrainInfo":{"TrainNo":"0101","Direction":0,"StartingStationID":"0990","EndingStationID":"1070","Overnight":false},"StopTimes":[{"StopSequence":1,"StationID":"0990","ArrivalTime":"08:00","DepartureTime":"08:01"}]}`
		sink := &fakeLoadSink{}
		if err := LoadThsrTimetable(context.Background(), decodeInto(`[`+row+`,`+row+`]`), sink, "2026-07-15"); err != nil {
			t.Fatalf("identical: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("identical rows = %+v, want one", sink.calls)
		}
		other := `{"TrainDate":"2026-07-15","DailyTrainInfo":{"TrainNo":"0101","Direction":0,"StartingStationID":"0990","EndingStationID":"1070","Overnight":false},"StopTimes":[{"StopSequence":1,"StationID":"0990","ArrivalTime":"08:02","DepartureTime":"08:03"}]}`
		err := LoadThsrTimetable(context.Background(), decodeInto(`[`+row+`,`+other+`]`), &fakeLoadSink{}, "2026-07-15")
		if err == nil || !errMentions(err, "duplicate timetable") {
			t.Fatalf("divergent error = %v", err)
		}
	})
}
