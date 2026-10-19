package search

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestEmbeddingResponseValidation(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   []float32
	}{
		{"first embedding", 200, `{"embeddings":[[1.25,-2],[9]]}`, []float32{1.25, -2}},
		{"upstream failure", 503, `{"error":"unavailable"}`, nil},
		{"malformed JSON", 200, `{`, nil},
		{"missing embedding", 200, `{"embeddings":[]}`, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/json" {
					t.Errorf("embedding request = %s, content type %q", r.Method, r.Header.Get("Content-Type"))
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer upstream.Close()
			t.Setenv("EMBED_URL", upstream.URL)
			got, err := embedQuery(t.Context(), "車站")
			if tc.want == nil {
				if err == nil {
					t.Fatal("invalid embedding response accepted")
				}
			} else if err != nil || !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("embedding = %v, error %v, want %v", got, err, tc.want)
			}
		})
	}
	t.Setenv("EMBED_URL", "")
	if _, err := embedQuery(t.Context(), "車站"); err == nil {
		t.Fatal("disabled embedder accepted request")
	}
}

type failedEmbeddingTransport struct{ err error }

func (f failedEmbeddingTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, f.err
}

func TestEmbeddingTransportErrorIsPreserved(t *testing.T) {
	want := errors.New("embedding connection refused")
	previous := _embedClient
	_embedClient = resty.NewWithClient(&http.Client{Transport: failedEmbeddingTransport{err: want}})
	t.Cleanup(func() { _embedClient = previous })
	t.Setenv("EMBED_URL", "http://embedding.invalid")
	got, err := embedQuery(t.Context(), "車站")
	if got != nil || !errors.Is(err, want) {
		t.Fatalf("embedding = %v, error %v, want connection error", got, err)
	}
}

func TestVectorSearchPropagatesEmbeddingAndQueryErrors(t *testing.T) {
	for _, embeddingFails := range []bool{true, false} {
		t.Run(map[bool]string{true: "embedding", false: "query"}[embeddingFails], func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if embeddingFails {
					w.WriteHeader(http.StatusServiceUnavailable)
					return
				}
				_, _ = w.Write([]byte(`{"embeddings":[[1.5,-2]]}`))
			}))
			defer upstream.Close()
			t.Setenv("EMBED_URL", upstream.URL)
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			queryErr := errors.New("vector database unavailable")
			if !embeddingFails {
				db.ExpectQuery(`(?s)FROM search_vector.*ORDER BY embedding`).WithArgs("[1.5,-2]", 3).WillReturnError(queryErr)
			}
			got, err := vectorSearch(t.Context(), "車站", 3, db)
			if err == nil || got != nil {
				t.Fatalf("failed vector search = %v, error %v", got, err)
			}
			if !embeddingFails && !errors.Is(err, queryErr) {
				t.Fatalf("query error = %v, want %v", err, queryErr)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestTextSearchDiscardsResultsOnTerminalRowError(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	want := errors.New("text search interrupted after row")
	rows := pgxmock.NewRows(_textSearchColumns).
		AddRow("bus_route", "R1", "307", "Taipei", "A", "B", nil, nil, 0, 1.0).
		CloseError(want)
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "307", textSearchBranchLimit(3), "Taipei").
		WillReturnRows(rows).RowsWillBeClosed()
	got, err := textSearch(t.Context(), "307", "Taipei", 3, db)
	if got != nil || !errors.Is(err, want) {
		t.Fatalf("partial text response = %v, error %v", got, err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestSearchRejectsEmptyQueriesBeforeDatabaseAccess(t *testing.T) {
	for _, query := range []string{"", "  \t "} {
		db := &deadlineSearchDB{t: t}
		got := performSearchRequest(t, db, query)
		if got.Code != http.StatusBadRequest || db.called {
			t.Fatalf("empty query status = %d, database queried = %v", got.Code, db.called)
		}
	}
}

func TestSearchMergingHonorsNonPositiveLimits(t *testing.T) {
	result := searchResult{Type: "bus_route", UID: "R1"}
	for _, limit := range []int{0, -1} {
		if got := mergeSearchResults(limit, []searchResult{result}); got != nil {
			t.Fatalf("merge limit %d = %v", limit, got)
		}
		if got := dedupeTextSearchCandidates([]textSearchCandidate{{result: result}}, limit); got != nil {
			t.Fatalf("dedupe limit %d = %v", limit, got)
		}
	}
}

func TestExpandedRoutesKeepPrimaryOrderAndUniqueIdentity(t *testing.T) {
	primary := []searchResult{{Type: "bus_station", UID: "S1"}, {Type: "bus_route", UID: "R1", Name: "primary"}}
	_, seen := stationRouteIdentities(primary)
	extra := []searchResult{
		{Type: "bus_route", UID: "R1", Name: "duplicate primary"},
		{Type: "bus_route", UID: "R2", Name: "first expansion"},
		{Type: "bus_route", UID: "R2", Name: "duplicate expansion"},
		{Type: "bus_route", UID: "R3", Name: "last expansion"},
	}
	want := append(append([]searchResult(nil), primary...), extra[1], extra[3])
	if got := appendStationRoutes(primary, extra, seen); !reflect.DeepEqual(got, want) {
		t.Fatalf("expanded routes = %v, want %v", got, want)
	}
}

func TestVectorSearchReturnsCompleteRowsOrError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"embeddings":[[1.5,-2]]}`))
	}))
	defer upstream.Close()
	t.Setenv("EMBED_URL", upstream.URL)
	columns := []string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}
	rowErr := errors.New("interrupted vector scan")
	for _, failure := range []bool{false, true} {
		db, err := pgxmock.NewPool()
		if err != nil {
			t.Fatal(err)
		}
		rows := pgxmock.NewRows(columns).AddRow("bike_station", "bike-1", "車站", "Taipei", "", "", nil, nil)
		if failure {
			rows.RowError(0, rowErr)
		}
		db.ExpectQuery(`(?s)FROM search_vector.*ORDER BY embedding`).WithArgs("[1.5,-2]", 3).WillReturnRows(rows).RowsWillBeClosed()
		got, err := vectorSearch(context.Background(), "車站", 3, db)
		if failure {
			if !errors.Is(err, rowErr) || got != nil {
				t.Fatalf("partial vector response = %v, error %v", got, err)
			}
		} else if err != nil || len(got) != 1 || got[0].UID != "bike-1" || got[0].Name != "車站" {
			t.Fatalf("vector response = %v, error %v", got, err)
		}
		if err := db.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
		db.Close()
	}
}
