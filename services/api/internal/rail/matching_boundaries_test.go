package rail

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestBookingValidationRejectsMissingJourneyAndMalformedPassengerCounts(t *testing.T) {
	booking, _ := stubBooking(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"result":"success","data":{"deeplink":"x"}}`))
	})
	router := bookingRouter(booking)
	valid := url.Values{"agency": {"hsr"}, "kind": {"web"}, "start_station": {"a"}, "end_station": {"b"}, "train_date": {"2026-07-18"}, "train_time": {"10:00"}, "train_number": {"103"}}
	for _, tc := range []struct{ field, value string }{
		{"end_station", ""}, {"train_time", "bad"}, {"train_number", "0"},
		{"adult_ticket", "invalid"}, {"ticket_type", "invalid"}, {"ticket_count", "invalid"},
	} {
		t.Run(tc.field+tc.value, func(t *testing.T) {
			values := url.Values{}
			for k, v := range valid {
				values[k] = append([]string(nil), v...)
			}
			values.Set(tc.field, tc.value)
			if rec := getBooking(router, values.Encode()); rec.Code != http.StatusBadRequest {
				t.Fatalf("invalid booking returned %d: %s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestRailTimetablePairingRejectsReverseMissingAndMalformedOrigin(t *testing.T) {
	trarows := []*traTimetableRow{
		{Trainno: "valid", Stationid: "end", Stopsequence: 2, Arrivaltime: time.Date(2026, 7, 18, 8, 30, 0, 0, time.UTC)},
		{Trainno: "missing", Stationid: "end", Stopsequence: 2},
		{Trainno: "reverse", Stationid: "end", Stopsequence: 1},
		{Trainno: "bad", Stationid: "end", Stopsequence: 2},
		{Trainno: "other", Stationid: "other", Stopsequence: 2},
	}
	tramp := map[string]*pb.TraTimetable{"valid": {Starting_Time: "2026-07-18T08:00:00Z"}, "reverse": {Starting_Time: "2026-07-18T08:00:00Z"}, "bad": {Starting_Time: "invalid"}}
	got := matchingTRATimetables(trarows, tramp, map[string]int{"valid": 1, "reverse": 2, "bad": 1}, "end")
	if len(got) != 1 || got[0] != tramp["valid"] || got[0].Travel_Time != "30m0s" {
		t.Fatalf("TRA pairs=%v", got)
	}
	thsrrows := []*thsrTimetableRow{
		{Trainno: "valid", Stationid: "end", Stopsequence: 2, Arrivaltime: "08:30:00"},
		{Trainno: "missing", Stationid: "end", Stopsequence: 2},
		{Trainno: "reverse", Stationid: "end", Stopsequence: 1},
		{Trainno: "bad", Stationid: "end", Stopsequence: 2, Arrivaltime: "invalid"},
		{Trainno: "other", Stationid: "other", Stopsequence: 2},
	}
	thsrmp := map[string]*pb.ThsaTimetable{"valid": {Starting_Time: "08:00:00"}, "reverse": {Starting_Time: "08:00:00"}, "bad": {Starting_Time: "08:00:00"}}
	thsrgot := matchingTHSRTimetables(thsrrows, thsrmp, map[string]int{"valid": 1, "reverse": 2, "bad": 1}, "end")
	if len(thsrgot) != 1 || thsrgot[0] != thsrmp["valid"] || thsrgot[0].Travel_Time != "30m0s" {
		t.Fatalf("THSR pairs=%v", thsrgot)
	}
}

func TestTHSRTimetableSeedsExcludeDeparturesBeforeRequestedTime(t *testing.T) {
	date := time.Date(2026, 7, 18, 8, 0, 0, 0, time.UTC)
	rows := []*thsrTimetableRow{
		{Trainno: "past", Stationid: "start", Departuretime: "07:59:59", Stopsequence: 1},
		{Trainno: "now", Stationid: "start", Departuretime: "08:00:00", Stopsequence: 1},
		{Trainno: "later", Stationid: "start", Departuretime: "08:00:01", Stopsequence: 1},
		{Trainno: "other", Stationid: "end", Departuretime: "08:00:01", Stopsequence: 2},
	}
	seeds, seq := thsrTimetableSeeds(rows, "start", date)
	if len(seeds) != 2 || seeds["now"] == nil || seeds["later"] == nil || len(seq) != 2 || seq["now"] != 1 {
		t.Fatalf("seeds=%v, sequences=%v", seeds, seq)
	}
}

func TestEmptyRailCachePayloadIsNeverStored(t *testing.T) {
	_, rc := railTestServices(t)
	key := "quality:rail-empty:" + t.Name()
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err() })
	got, err := railRead(t.Context(), rc, "empty", key, _railDayTTL, func(context.Context) ([]byte, int, error) { return nil, 1, nil })
	if err != nil || got != nil {
		t.Fatalf("empty payload=%v, error=%v", got, err)
	}
	if exists, err := rc.Exists(t.Context(), key).Result(); err != nil || exists != 0 {
		t.Fatalf("empty payload cache entry=%d, error=%v", exists, err)
	}
}

func TestTRAFareMissingInputIsInvalidArgument(t *testing.T) {
	server := &TraTimetableServer{}
	for _, in := range []*pb.AskStaiton{{StationId: "origin"}, {Date: "destination"}, {}} {
		if response, err := server.Fare(t.Context(), in); response != nil || status.Code(err) != codes.InvalidArgument {
			t.Fatalf("missing fare input=%v, error=%v", response, err)
		}
	}
}

func TestRailPayloadMarshalFailureReturnsZeroCount(t *testing.T) {
	data, count, err := marshalRailPayload(&pb.TraStoptimes{Items: []*pb.TraStoptime{{StationName: string([]byte{0xff})}}}, 1)
	if data != nil || count != 0 || err == nil {
		t.Fatalf("invalid string payload=%v count=%d error=%v", data, count, err)
	}
}

func TestValidBookingPassengerClassAndCountReachTRAUpstream(t *testing.T) {
	booking, _ := stubBooking(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("ticket_type") != "3" || r.URL.Query().Get("ticket_count") != "9" {
			t.Errorf("booking query=%v", r.URL.Query())
		}
		_, _ = w.Write([]byte(`{"result":"success","data":{"deeplink":"x"}}`))
	})
	rec := getBooking(bookingRouter(booking), "agency=tra&kind=web&start_station=a&end_station=b&train_date=2026-07-18&train_number=103&ticket_type=3&ticket_count=9")
	if rec.Code != http.StatusOK {
		t.Fatalf("valid booking=%d, body=%s", rec.Code, rec.Body.String())
	}
}

func TestRailReadLoadFailurePreservesErrorAndAvoidsCaching(t *testing.T) {
	_, rc := railTestServices(t)
	key := "quality:rail-load-error:" + t.Name()
	t.Cleanup(func() { _ = rc.Del(context.Background(), key).Err() })
	want := errors.New("database unavailable")
	got, err := railRead(t.Context(), rc, "failure", key, _railDayTTL, func(context.Context) ([]byte, int, error) { return nil, 0, want })
	if got != nil || !errors.Is(err, want) {
		t.Fatalf("load failure=%v, error=%v", got, err)
	}
	if exists, err := rc.Exists(t.Context(), key).Result(); err != nil || exists != 0 {
		t.Fatalf("failed read cache=%d, error=%v", exists, err)
	}
}
