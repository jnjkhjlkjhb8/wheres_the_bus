package rail

import (
	"context"
	"encoding/json"
	"testing"
)

func TestThsrLoadRejectsMissingFareCodesAndStopsBeforeWriting(t *testing.T) {
	for _, field := range []string{"TicketType", "FareClass", "CabinClass"} {
		item := map[string]any{"TicketType": 1, "FareClass": 1, "CabinClass": 1, "Price": 20}
		delete(item, field)
		body, err := json.Marshal([]any{map[string]any{"OriginStationID": "0990", "DestinationStationID": "1070", "Fares": []any{item}}})
		if err != nil {
			t.Fatal(err)
		}
		sink := &fakeLoadSink{}
		if err := LoadThsrFare(context.Background(), decodeInto(string(body)), sink, ""); err == nil || !errMentions(err, field) {
			t.Fatalf("%s: %v", field, err)
		}
		if len(sink.calls) != 0 {
			t.Fatal("invalid fare reached sink")
		}
	}
	payload := validThsrPresencePayload()
	payload["StopTimes"] = []any{}
	body, err := json.Marshal([]any{payload})
	if err != nil {
		t.Fatal(err)
	}
	if err := LoadThsrTimetable(context.Background(), decodeInto(string(body)), &fakeLoadSink{}, "2026-07-15"); err == nil || !errMentions(err, "StopTimes") {
		t.Fatalf("empty StopTimes: %v", err)
	}
	if err := LoadThsrTimetable(context.Background(), decodeInto(`[]`), &fakeLoadSink{}, "2026-02-30"); err == nil {
		t.Fatal("invalid partition date accepted")
	}
	sink := &fakeLoadSink{}
	if err := LoadThsrStation(context.Background(), decodeInto(`[]`), sink, ""); err != nil {
		t.Fatal(err)
	}
	if len(sink.calls) != 0 {
		t.Fatal("empty station feed reached sink")
	}
}

func TestRailRowBuildersRejectCorruptClockBeforeStaging(t *testing.T) {
	for _, field := range []string{"ArrivalTime", "DepartureTime"} {
		for _, mode := range []string{"TRA", "THSR"} {
			payload := validTraPresencePayload()
			if mode == "THSR" {
				payload = validThsrPresencePayload()
			}
			payload["StopTimes"].([]any)[0].(map[string]any)[field] = "invalid"
			body, err := json.Marshal(payload)
			if err != nil {
				t.Fatal(err)
			}
			if mode == "TRA" {
				var row rawTraTimetable
				if err := json.Unmarshal(body, &row); err != nil {
					t.Fatal(err)
				}
				_, err = traTimetableRows([]rawTraTimetable{row}, "2026-07-15")
			} else {
				var row rawThsrTimetable
				if err := json.Unmarshal(body, &row); err != nil {
					t.Fatal(err)
				}
				_, err = thsrTimetableRows([]rawThsrTimetable{row})
			}
			if err == nil || !errMentions(err, field) {
				t.Fatalf("%s %s: %v", mode, field, err)
			}
		}
	}
}
