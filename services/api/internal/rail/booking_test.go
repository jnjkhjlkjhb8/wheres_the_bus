package rail

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
)

// stubBooking builds a bookingProxy whose upstream clients point at a fake TDX
// that echoes the given handler, so the exchange path is exercised without real
// credentials or network.
func stubBooking(t *testing.T, handler http.HandlerFunc) (*BookingProxy, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		handler(w, r)
	}))
	t.Cleanup(srv.Close)
	client := resty.New().SetBaseURL(srv.URL)
	return &BookingProxy{tra: client, thsr: client}, srv
}

func bookingRouter(booking *BookingProxy) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/api/booking/deeplink", HandleBookingDeeplink(booking))
	return r
}

func getBooking(r *gin.Engine, query string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/api/booking/deeplink?"+query, nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	return rec
}

func TestBookingRoute(t *testing.T) {
	b := &BookingProxy{tra: resty.New(), thsr: resty.New()}
	cases := []struct {
		agency, kind string
		wantOK       bool
		wantPath     string
	}{
		{"tra", "direct", true, "/booking/deeplink/direct/tra"},
		{"tra", "web", true, "/booking/deeplink/web/tra"},
		{"hsr", "direct", true, "/booking/deeplink/direct/hsr"},
		{"hsr", "web", true, "/booking/deeplink/web/hsr"},
		{"tra", "store", false, ""},
		{"bus", "web", false, ""},
	}
	for _, tc := range cases {
		_, path, ok := b.route(tc.agency, tc.kind)
		if ok != tc.wantOK || path != tc.wantPath {
			t.Errorf("route(%q,%q) = (%q,%v), want (%q,%v)", tc.agency, tc.kind, path, ok, tc.wantPath, tc.wantOK)
		}
	}
}

func TestBookingDeeplinkSuccess(t *testing.T) {
	var gotPath, gotStart, gotDate string
	booking, _ := stubBooking(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotStart = r.URL.Query().Get("start_station")
		// The direct variant dates by `train_date`; the web variants rename it.
		// Getting this wrong is what made every exchange fall back silently.
		gotDate = r.URL.Query().Get("train_date")
		_, _ = w.Write([]byte(`{"result":"success","data":{"deeplink":"https://maas.transportdata.tw/x?token=abc","expired":"2026-07-18 04:13:20"}}`))
	})
	rec := getBooking(bookingRouter(booking),
		"agency=tra&kind=direct&start_station=%E8%87%BA%E5%8C%97&end_station=%E9%AB%98%E9%9B%84&train_date=2026-07-18&train_time=10%3A00&train_number=103")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	if gotPath != "/booking/deeplink/direct/tra" || gotStart != "臺北" || gotDate != "2026-07-18" {
		t.Fatalf("upstream got path=%q start=%q train_date=%q", gotPath, gotStart, gotDate)
	}
	var out map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out["url"], "token=abc") {
		t.Fatalf("url = %q", out["url"])
	}
}

func TestBookingDeeplinkUpstreamFailure(t *testing.T) {
	booking, _ := stubBooking(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"result":"fail","error":{"msg":"no such train"}}`))
	})
	rec := getBooking(bookingRouter(booking),
		"agency=tra&kind=web&start_station=a&end_station=b&train_date=2026-07-18&train_time=10%3A00&train_number=103")
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", rec.Code)
	}
}

// The upstream body is the only thing that distinguishes a rejected station
// name from an unsubscribed API, so a failed exchange must carry it out to the
// log line rather than collapsing to a bare status.
func TestBookingExchangeErrorCarriesUpstreamDetail(t *testing.T) {
	booking, _ := stubBooking(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"result":"fail","error":{"msg":"no such train"}}`))
	})
	_, _, err := booking.exchange(t.Context(), booking.tra, "/booking/deeplink/web/tra", bookingRequest{
		agency: "tra", kind: "web", start: "a", end: "b", date: "2026-07-18", time: "10:00", train: "103",
	})
	if err == nil {
		t.Fatal("exchange succeeded, want failure")
	}
	// `result` stays empty here: resty only unmarshals SetResult on 2xx, which
	// is precisely why the raw body has to be logged alongside it.
	for _, want := range []string{"status=403", "no such train"} {
		if !errMentions(err, want) {
			t.Errorf("error %q is missing %q", err, want)
		}
	}
}

// The three variants take genuinely different parameters; sending one shared
// set is what made every exchange fail. Each row here is a spec fact.
func TestBookingParamsPerVariant(t *testing.T) {
	base := bookingRequest{
		start: "台北", end: "左營", date: "2026-07-18", time: "10:00", train: "309",
	}
	t.Run("hsr web takes yyyymmdd, a padded number and per-category counts", func(t *testing.T) {
		r := base
		r.agency, r.kind, r.carriage = "hsr", "web", "J"
		r.tickets = map[string]int{"adult": 2, "senior": 1}
		q := bookingParams(r)
		want := map[string]string{
			"departure_date": "20260718", "departure_number": "0309",
			"ticket_type": "S", "carriage_type": "J",
			"adult_ticket": "2", "senior_ticket": "1",
			"children_ticket": "0", "disabled_ticket": "0", "student_ticket": "0",
		}
		for k, v := range want {
			if q[k] != v {
				t.Errorf("%s = %q, want %q", k, q[k], v)
			}
		}
		if _, ok := q["train_date"]; ok {
			t.Error("hsr web must not send train_date")
		}
	})
	t.Run("tra web takes departure_date, a booking class and one count", func(t *testing.T) {
		r := base
		r.agency, r.kind = "tra", "web"
		r.traClass, r.traCount = 2, 3
		q := bookingParams(r)
		// Same fields as the direct variant, different names — the number moves
		// to departure_number while the date keeps its yyyy-mm-dd form.
		if q["departure_date"] != "2026-07-18" || q["departure_number"] != "309" {
			t.Errorf("tra web params = %v", q)
		}
		if _, ok := q["train_number"]; ok {
			t.Error("tra web must not send train_number")
		}
		// TRA's ticket_type is the booking class (2 = 騰雲座艙), unrelated to
		// THSR's ticket_type, which is the trip type.
		if q["ticket_type"] != "2" || q["ticket_count"] != "3" {
			t.Errorf("tra ticket params = %v", q)
		}
		if _, ok := q["train_time"]; ok {
			t.Error("tra must not send train_time")
		}
	})
	t.Run("tra web defaults an unset class and count", func(t *testing.T) {
		r := base
		r.agency, r.kind = "tra", "web"
		q := bookingParams(r)
		if q["ticket_type"] != "1" || q["ticket_count"] != "1" {
			t.Errorf("tra defaults = ticket_type %q count %q", q["ticket_type"], q["ticket_count"])
		}
	})
	t.Run("tra direct takes train_date and no train_time", func(t *testing.T) {
		r := base
		r.agency, r.kind = "tra", "direct"
		q := bookingParams(r)
		if q["train_date"] != "2026-07-18" || q["train_number"] != "309" {
			t.Errorf("tra direct params = %v", q)
		}
		if _, ok := q["departure_date"]; ok {
			t.Error("direct must not send departure_date")
		}
		// TRA has no train_time field at all.
		if _, ok := q["train_time"]; ok {
			t.Error("tra must not send train_time")
		}
	})
	t.Run("hsr direct takes train_date plus train_time", func(t *testing.T) {
		r := base
		r.agency, r.kind = "hsr", "direct"
		q := bookingParams(r)
		if q["train_date"] != "2026-07-18" || q["train_time"] != "10:00" {
			t.Errorf("hsr direct params = %v", q)
		}
	})
}

func TestBookingDeeplinkBadRequests(t *testing.T) {
	booking, _ := stubBooking(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"result":"success","data":{"deeplink":"x"}}`))
	})
	r := bookingRouter(booking)
	bad := []string{
		"agency=tra&kind=store&start_station=a&end_station=b&train_date=2026-07-18&train_time=10%3A00&train_number=103", // bad kind
		"agency=tra&kind=web&start_station=a&end_station=b&train_date=20260718&train_time=10%3A00&train_number=103",     // bad date
		"agency=tra&kind=web&start_station=a&end_station=b&train_date=2026-07-18&train_time=10%3A00&train_number=abc",   // bad train
		"agency=tra&kind=web&start_station=&end_station=b&train_date=2026-07-18&train_time=10%3A00&train_number=103",    // empty station
		"agency=tra&kind=web&start_station=a&end_station=b&train_date=2026-07-18&train_number=103&ticket_count=10",      // over TRA's 9-ticket ceiling
		"agency=tra&kind=web&start_station=a&end_station=b&train_date=2026-07-18&train_number=103&ticket_type=4",        // no such booking class
	}
	for _, q := range bad {
		if rec := getBooking(r, q); rec.Code != http.StatusBadRequest {
			t.Errorf("query %q: status = %d, want 400", q, rec.Code)
		}
	}
}

func TestBookingDeeplinkUnavailableWhenNil(t *testing.T) {
	rec := getBooking(bookingRouter(nil),
		"agency=tra&kind=web&start_station=a&end_station=b&train_date=2026-07-18&train_time=10%3A00&train_number=103")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}
