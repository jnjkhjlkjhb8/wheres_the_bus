package bus

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

func gzipBusJSON(t *testing.T, raw string) []byte {
	t.Helper()
	var b bytes.Buffer
	w := gzip.NewWriter(&b)
	if _, err := w.Write([]byte(raw)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestDataTaipeiHTTPMaintainsEachBlobETagAndRows(t *testing.T) {
	blobs := map[string]string{
		"/GetBusData.gz":      `{"BusInfo":[{"BusID":"plate","RouteID":"123","GoBack":"0","Longitude":"121.5","Latitude":"25","Speed":"2","Azimuth":"90","DataTime":"2026-10-10 09:00:00"}]}`,
		"/GetBusEvent.gz":     `{"BusInfo":[{"BusID":"plate","StopID":"5","CarOnStop":"1"}]}`,
		"/BusSeatEvent.gz":    `{"BusInfo":[{"BusID":"plate","Level":2}]}`,
		"/GetEstimateTime.gz": `{"BusInfo":[{"RouteID":123,"StopID":5,"EstimateTime":"60","GoBack":"0"}]}`,
	}
	counts := map[string]int{}
	badHeader := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		counts[r.URL.Path]++
		etag := fmt.Sprintf("\"%s\"", r.URL.Path)
		if counts[r.URL.Path] > 1 {
			if r.Header.Get("If-None-Match") != etag {
				badHeader = r.Header.Get("If-None-Match")
			}
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", etag)
		_, _ = w.Write(gzipBusJSON(t, blobs[r.URL.Path]))
	}))
	defer server.Close()
	f := &dataTaipeiFeed{client: resty.New().SetBaseURL(server.URL), prefix: "TPE", city: "Taipei", etag: map[string]string{}}
	first, err := f.positions(context.Background())
	if err != nil || len(first) != 1 {
		t.Fatalf("positions=%v %v", first, err)
	}
	p := first[0]
	if p.SubRouteUID != "TPE123" || p.PlateNumb != "plate" || p.StopUID != "TPE5" || p.Direction != 0 || p.Speed != 2 || p.Azimuth != 90 || p.CrowdLevel != models.BusCrowdLevel_BUS_CROWD_CROWDED {
		t.Fatalf("position=%v", p)
	}
	estimates, err := f.estimates(context.Background())
	if err != nil || len(estimates) != 1 || estimates[0].StopUID != "TPE5" || estimates[0].RouteUID != "TPE123" || estimates[0].EstimatedTime != 60 || estimates[0].StopStatus != 0 {
		t.Fatalf("estimates=%v %v", estimates, err)
	}
	cached, err := f.positions(context.Background())
	if err != nil || !reflect.DeepEqual(cached, first) {
		t.Fatalf("cached positions=%v %v", cached, err)
	}
	cachedETA, err := f.estimates(context.Background())
	if err != nil || !reflect.DeepEqual(cachedETA, estimates) {
		t.Fatalf("cached ETA=%v %v", cachedETA, err)
	}
	if badHeader != "" {
		t.Fatalf("ETag header=%q", badHeader)
	}
	for path, n := range counts {
		if n != 2 {
			t.Fatalf("requests %s=%d", path, n)
		}
	}
}

func TestDataTaipeiHTTPRejectsInvalidResponsesWithoutReplacingRows(t *testing.T) {
	status := http.StatusBadGateway
	body := []byte("unavailable")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(status); _, _ = w.Write(body) }))
	defer server.Close()
	f := &dataTaipeiFeed{client: resty.New().SetBaseURL(server.URL), etag: map[string]string{}}
	for _, tc := range []struct {
		status int
		body   []byte
	}{{502, []byte("bad")}, {200, []byte{0x1f, 0x8b}}, {200, []byte("not JSON")}, {200, []byte(`{"BusInfo":"bad"}`)}} {
		status, body = tc.status, tc.body
		var out []dataTaipeiBus
		if fresh, err := f.getRows(context.Background(), "GetBusData", &out); err == nil || fresh {
			t.Fatalf("invalid response fresh=%v err=%v", fresh, err)
		}
	}
	status = 502
	f.buses = []dataTaipeiBus{{BusID: "retained"}}
	f.estimateRows = []dataTaipeiEstimate{{StopID: 1}}
	if _, err := f.positions(context.Background()); err == nil {
		t.Fatal("positions discarded HTTP error")
	}
	if len(f.buses) != 1 || f.buses[0].BusID != "retained" {
		t.Fatal("failed blobs replaced cached buses")
	}
	if _, err := f.estimates(context.Background()); err == nil || len(f.estimateRows) != 1 {
		t.Fatal("estimates discarded error or cache")
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	var out any
	if _, err := f.getEnvelope(canceled, "GetBusData", &out); err == nil {
		t.Fatal("canceled GET succeeded")
	}
	for _, raw := range [][]byte{nil, {0x1f}, []byte("plain"), {0x1f, 0x00}} {
		got, err := gunzipIfCompressed(raw)
		if err != nil || !bytes.Equal(got, raw) {
			t.Fatalf("plain bytes=%v %v", got, err)
		}
	}
	compressed := gzipBusJSON(t, "valid")
	compressed[len(compressed)-1] ^= 0xff
	if _, err := gunzipIfCompressed(compressed); err == nil {
		t.Fatal("invalid gzip checksum accepted")
	}
}

func TestModelStopTimeClassifiesScheduleAndModelAndMissingReadings(t *testing.T) {
	at := time.Date(2026, 10, 10, 9, 0, 0, 0, time.UTC)
	for _, offset := range []bool{false, true} {
		got, source := decodeModelStopTime(at.Format(time.RFC3339), offset)
		want := history.SourceSchedule
		if offset {
			want = history.SourceModel
		}
		if !got.Equal(at) || source != want {
			t.Fatalf("prediction=%v %s", got, source)
		}
	}
	for _, text := range []string{"", "malformed"} {
		at, source := decodeModelStopTime(text, false)
		if !at.IsZero() || source != "" {
			t.Fatalf("missing prediction=%v %s", at, source)
		}
	}
	b := busmodel.StationMap{SubRouteUID: "R", StopUID: "S"}
	rk := predict.RouteDirKey{SubRouteUID: "R"}
	r := &busCitySnapshot{city: "Taipei", now: at, totalStops: map[string]int{}, depMap: map[predict.RouteDirKey]time.Time{}, offsetMap: map[predict.StopOffsetKey]int{}}
	text, got, source := r.modelStopTime(b, rk)
	if text != "" || !got.IsZero() || source != "" {
		t.Fatalf("no departure/model=%q %v %s", text, got, source)
	}
	if _, err := decodeBusEtaArray(json.NewDecoder(strings.NewReader(`[{}] null`))); err == nil {
		t.Fatal("trailing array data accepted")
	}
}
