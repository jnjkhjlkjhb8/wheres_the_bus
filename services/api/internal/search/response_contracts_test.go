package search

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	pgxmock "github.com/pashagolub/pgxmock/v4"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestSearchAcceptsExactCityAndLimitBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name, query, city, limit string
		branch                   int
	}{
		{"city maximum", "中正", strings.Repeat("臺", 32), "", 100},
		{"query maximum", strings.Repeat("站", 128), "Taipei", "", 100},
		{"zero uses default", "中正", "Taipei", "0", 100},
		{"maximum limit", "中正", "Taipei", "50", 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
				WithArgs(pgx.QueryExecModeExec, tc.query, tc.branch, tc.city).
				WillReturnRows(pgxmock.NewRows(_textSearchColumns).
					AddRow("bus_route", "R1", "中正", "Taipei", "A", "B", nil, nil, 1, 1.0))
			target := "/api/search?" + url.Values{"q": {tc.query}, "city": {tc.city}, "limit": {tc.limit}}.Encode()
			got := newSearchRouter(t, db).get(t, target)
			if got.Code != http.StatusOK || !strings.Contains(got.Body.String(), `"uid":"R1"`) {
				t.Fatalf("boundary response = %d %s", got.Code, got.Body.String())
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSearchRecognizesZeroAndNineAsTrainNumbers(t *testing.T) {
	for _, query := range []string{"0", "9"} {
		t.Run(query, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			db.ExpectQuery(`(?s)WHERE uid = \$1 AND type IN`).WithArgs(query).
				WillReturnRows(pgxmock.NewRows([]string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}).
					AddRow("tra_train", query, "train", "", "A", "B", nil, nil))
			db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
				WithArgs(pgx.QueryExecModeExec, query, 100, "").WillReturnRows(pgxmock.NewRows(_textSearchColumns))
			got := newSearchRouter(t, db).get(t, "/api/search?q="+query)
			if got.Code != http.StatusOK || !strings.Contains(got.Body.String(), `"type":"tra_train"`) {
				t.Fatalf("train response = %d %s", got.Code, got.Body.String())
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSearchResponseOrdersRankThenSimilarityThenName(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "紅線", 25, "Taipei").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_route", "R", "A", "Taipei", "", "", nil, nil, 1, 0.7).
			AddRow("bus_route", "Q", "Z", "Taipei", "", "", nil, nil, 1, 0.8).
			AddRow("bus_route", "P", "Z", "Taipei", "", "", nil, nil, 0, 0.1).
			AddRow("bus_route", "T", "A", "Taipei", "", "", nil, nil, 1, 0.8).
			AddRow("bus_route", "U", "A", "Taipei", "", "", nil, nil, 1, 0.8))
	response := newSearchRouter(t, db).get(t, "/api/search?q="+url.QueryEscape("紅線")+"&city=Taipei&limit=5")
	if response.Code != http.StatusOK {
		t.Fatalf("ranked response = %d %s", response.Code, response.Body.String())
	}
	var body struct {
		Results []searchResult `json:"results"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, result := range body.Results {
		ids = append(ids, result.UID)
	}
	if !reflect.DeepEqual(ids, []string{"P", "T", "U", "Q", "R"}) {
		t.Fatalf("ranked identities = %v, want [P T U Q R]", ids)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestGeocodeAcceptsQueryAndCoordinateBoundaries(t *testing.T) {
	queries := make(chan url.Values, 4)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		queries <- request.URL.Query()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[]`))
	}))
	defer upstream.Close()
	router := geocodeTestRouter(t, upstream.URL, true)
	for _, tc := range []struct{ lat, lon, place string }{
		{"90", "121.5", "90.000000,121.500000"},
		{"-90", "121.5", "-90.000000,121.500000"},
		{"25", "180", "25.000000,180.000000"},
		{"25", "-180", "25.000000,-180.000000"},
	} {
		query := url.Values{"text": {strings.Repeat("站", 120)}, "lat": {tc.lat}, "lon": {tc.lon}}
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, GeocodePath+"?"+query.Encode(), nil))
		if recorder.Code != http.StatusOK {
			t.Fatalf("boundary geocode = %d; want 200", recorder.Code)
		}
		gotQuery := <-queries
		if gotQuery.Get("place") != tc.place {
			t.Fatalf("geocode bias = %q; want %q", gotQuery.Get("place"), tc.place)
		}
	}
}

func TestGeocodeUpstreamDiagnosticKeepsHTTPStatus(t *testing.T) {
	core, logs := observer.New(zap.WarnLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer upstream.Close()
	recorder := httptest.NewRecorder()
	geocodeTestRouter(t, upstream.URL, true).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, GeocodePath+"?text=station", nil))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("failed geocode response = %d, want 503", recorder.Code)
	}
	entries := logs.FilterMessage("geocode upstream failed").All()
	if len(entries) != 1 || entries[0].ContextMap()["status_code"] != int64(http.StatusBadGateway) {
		t.Fatalf("upstream diagnostics = %v, want one status_code=502 entry", entries)
	}
}
