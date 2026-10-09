package search

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/gin-gonic/gin"
)

func geocodeTestRouter(t *testing.T, upstreamURL string, mounted bool) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	RegisterGeocodeRoutes(engine, upstreamURL, mounted, func(c *gin.Context) { c.Next() })
	return engine
}

// An upstream failure must not look like "there is no such place": the app
// falls back to Google Places on an error, and an empty 200 would tell it the
// search genuinely came up empty and to stop looking.
func TestHandleGeocodeReportsUpstreamFailureRatherThanEmptyResults(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer upstream.Close()

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, GeocodePath+"?text=台北車站", nil)
	geocodeTestRouter(t, upstream.URL, true).ServeHTTP(recorder, request)

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", recorder.Code)
	}
}

func TestHandleGeocodeMapsMatchesAndDropsUnnavigableOnes(t *testing.T) {
	var gotQuery url.Values
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.Query()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[
			{"type":"STOP","name":"台北車站","id":"a","lat":25.0478,"lon":121.5170},
			{"type":"ADDRESS","name":"忠孝東路一段","id":"b","lat":25.0440,"lon":121.5220,"street":"忠孝東路一段","houseNumber":"12"},
			{"type":"PLACE","name":"沒有座標","id":"c","lat":0,"lon":0}
		]`))
	}))
	defer upstream.Close()

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, GeocodePath+"?text=台北&lat=25.03&lon=121.56", nil)
	geocodeTestRouter(t, upstream.URL, true).ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	var body struct {
		Suggestions []geocodeSuggestion `json:"suggestions"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	// A row with no coordinates is one the rider can tap and get nothing from.
	if len(body.Suggestions) != 2 {
		t.Fatalf("suggestions = %d, want 2 (the coordinate-less one dropped)", len(body.Suggestions))
	}
	// Taiwan writes the number after the street, not before it.
	if body.Suggestions[1].Address != "忠孝東路一段12號" {
		t.Errorf("address = %q", body.Suggestions[1].Address)
	}
	if got := gotQuery.Get("place"); got != "25.030000,121.560000" {
		t.Errorf("place bias = %q", got)
	}
}

// Without the bias a query like 車站 is scored against the whole island, so a
// coordinate that cannot be trusted must be dropped rather than sent: biasing
// towards 0,0 pulls every Taiwan result away from the rider.
func TestGeocodeBiasRejectsUnusableCoordinates(t *testing.T) {
	tests := []struct{ lat, lon string }{
		{lat: "", lon: ""},
		{lat: "0", lon: "0"},
		{lat: "abc", lon: "121.5"},
		{lat: "95", lon: "121.5"},
	}
	for _, tt := range tests {
		if _, ok := geocodeBias(tt.lat, tt.lon); ok {
			t.Errorf("geocodeBias(%q, %q) was accepted", tt.lat, tt.lon)
		}
	}
	if _, ok := geocodeBias("25.03", "121.56"); !ok {
		t.Error("a valid Taipei coordinate was rejected")
	}
}

// With MAAS_BACKEND=tdx there is no MOTIS to proxy, so the route must not
// exist: a 404 sends the app to Google Places, while a mounted route pointing
// at nothing would spend three seconds timing out on every keystroke.
func TestRegisterGeocodeRoutesStaysUnmountedWithoutMotis(t *testing.T) {
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, GeocodePath+"?text=台北", nil)
	geocodeTestRouter(t, "http://motis:8080", false).ServeHTTP(recorder, request)

	if recorder.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", recorder.Code)
	}
}
