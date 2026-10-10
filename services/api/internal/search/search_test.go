package search

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

type deadlineSearchDB struct {
	t      *testing.T
	called bool
}

func (d *deadlineSearchDB) Query(ctx context.Context, _ string, _ ...any) (pgx.Rows, error) {
	d.t.Helper()
	d.called = true
	deadline, ok := ctx.Deadline()
	if !ok {
		d.t.Fatal("search query context has no deadline")
	}
	if remaining := time.Until(deadline); remaining <= 0 || remaining > _searchRequestTimeout {
		d.t.Fatalf("search query deadline remaining = %v, want within %v", remaining, _searchRequestTimeout)
	}
	return nil, errors.New("stop after context inspection")
}

var _textSearchColumns = []string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon", "rank", "sim"}

func performSearchRequest(t *testing.T, db searchDB, query string) *httptest.ResponseRecorder {
	t.Helper()
	return newSearchRouter(t, db).get(t, "/api/search?q="+url.QueryEscape(query))
}

// searchRouter keeps one handler (and therefore one response cache) across
// several requests, which is what the cache tests need to observe.
type searchRouter struct{ engine *gin.Engine }

func newSearchRouter(t *testing.T, db searchDB) searchRouter {
	t.Helper()
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	engine.GET("/api/search", HandleSearch(db))
	return searchRouter{engine: engine}
}

func (r searchRouter) get(t *testing.T, target string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	r.engine.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, target, nil))
	return recorder
}

func TestHandleSearchPassesCityFilterToQuery(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "中正路", textSearchBranchLimit(20), "Taipei").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_route", "R-1", "中正幹線", "Taipei", "A", "B", nil, nil, 2, 0.9))

	got := newSearchRouter(t, db).get(t, "/api/search?q="+url.QueryEscape("中正路")+"&city=Taipei")
	if got.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s, want 200", got.Code, got.Body.String())
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestHandleSearchRejectsOverlongCity keeps the response cache's keyspace
// bounded by the length cap rather than by whatever a caller sends.
func TestHandleSearchRejectsOverlongCity(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db := &deadlineSearchDB{t: t}

	got := newSearchRouter(t, db).get(t,
		"/api/search?q=台北&city="+strings.Repeat("x", _maxSearchCityRunes+1))
	if got.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s, want 400", got.Code, got.Body.String())
	}
	if db.called {
		t.Fatal("database was queried for a rejected city filter")
	}
}

// TestHandleSearchServesRepeatQueryFromCache guards the cache: search_vector
// is rewritten once a day, so a repeated query must not repeat the scan.
func TestHandleSearchServesRepeatQueryFromCache(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// Exactly one text-search expectation for two identical requests.
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "紅30", textSearchBranchLimit(20), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_route", "R-1", "紅30", "Kaohsiung", "A", "B", nil, nil, 1, 1.0))

	router := newSearchRouter(t, db)
	target := "/api/search?q=" + url.QueryEscape("紅30")
	first := router.get(t, target)
	second := router.get(t, target)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("statuses = %d/%d, want 200/200", first.Code, second.Code)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("cached body = %s, want the same as %s", second.Body.String(), first.Body.String())
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestHandleSearchCacheKeyIncludesCity stops a filtered response from being
// served to an unfiltered request, which would silently hide other cities.
func TestHandleSearchCacheKeyIncludesCity(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "中正路", textSearchBranchLimit(20), "Taipei").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_station", "S-1", "中正路", "Taipei", "", "", nil, nil, 1, 1.0))
	db.ExpectQuery(`(?s)FROM bus_station_group_members`).
		WithArgs([]string{"S-1"}).
		WillReturnRows(pgxmock.NewRows([]string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}))
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "中正路", textSearchBranchLimit(20), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_station", "S-9", "中正路", "Kaohsiung", "", "", nil, nil, 1, 1.0))
	db.ExpectQuery(`(?s)FROM bus_station_group_members`).
		WithArgs([]string{"S-9"}).
		WillReturnRows(pgxmock.NewRows([]string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}))

	router := newSearchRouter(t, db)
	q := url.QueryEscape("中正路")
	filtered := router.get(t, "/api/search?q="+q+"&city=Taipei")
	unfiltered := router.get(t, "/api/search?q="+q)
	if body := filtered.Body.String(); !strings.Contains(body, "S-1") {
		t.Fatalf("filtered body = %s, want the Taipei row", body)
	}
	if body := unfiltered.Body.String(); !strings.Contains(body, "S-9") {
		t.Fatalf("unfiltered body = %s, want the unfiltered row, not the cached Taipei one", body)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// TestHandleSearchSkipsRouteExpansionOnFullPage: expansion only ever adds
// rows, so on a full page every added row is dropped by the final cap —
// the join is a second round trip spent on nothing.
func TestHandleSearchSkipsRouteExpansionOnFullPage(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// A bus_station result would normally trigger the expansion join; the
	// mock declares no expectation for it, so running it fails the test.
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "中正", textSearchBranchLimit(2), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_station", "S-1", "中正路", "Taipei", "", "", nil, nil, 1, 1.0).
			AddRow("bus_station", "S-2", "中正路口", "NewTaipei", "", "", nil, nil, 1, 0.9))

	got := newSearchRouter(t, db).get(t, "/api/search?q="+url.QueryEscape("中正")+"&limit=2")
	if got.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s, want 200", got.Code, got.Body.String())
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestHandleSearchLimitsQueryByUnicodeRunes(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, strings.Repeat("界", 128), textSearchBranchLimit(20), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns))

	if got := performSearchRequest(t, db, strings.Repeat("界", 128)); got.Code != http.StatusOK {
		t.Fatalf("128-rune status = %d, body = %s, want 200", got.Code, got.Body.String())
	}
	if got := performSearchRequest(t, db, strings.Repeat("界", 129)); got.Code != http.StatusBadRequest {
		t.Fatalf("129-rune status = %d, body = %s, want 400", got.Code, got.Body.String())
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestEmbedQueryHonorsContextCancellation(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		close(started)
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer func() {
		close(release)
		upstream.Close()
	}()
	t.Setenv("EMBED_URL", upstream.URL)

	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() {
		_, err := embedQuery(ctx, "台北車站")
		errCh <- err
	}()
	<-started
	cancel()

	select {
	case err := <-errCh:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("err = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("embed request did not stop after cancellation")
	}
}

func TestEmbedQueryHonorsContextDeadline(t *testing.T) {
	release := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer func() {
		close(release)
		upstream.Close()
	}()
	t.Setenv("EMBED_URL", upstream.URL)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, err := embedQuery(ctx, "台北車站")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want context.DeadlineExceeded", err)
	}
}

func TestHandleSearchBoundsDatabaseQuery(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db := &deadlineSearchDB{t: t}

	got := performSearchRequest(t, db, "台北")
	if got.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, body = %s, want 500", got.Code, got.Body.String())
	}
	if !db.called {
		t.Fatal("database query was not called")
	}
}

func TestTextSearchReturnsScanError(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "台北", textSearchBranchLimit(20), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow(struct{}{}, "uid", "name", "city", "depart", "destin", nil, nil, 0, 1.0))

	results, err := textSearch(context.Background(), "台北", "", 20, db)
	if err == nil {
		t.Fatalf("results = %#v, want scan error", results)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestExpandStationRoutesReturnsRowsErrorWithoutPartialResults(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	wantErr := errors.New("route expansion rows failed")

	db.ExpectQuery(`(?s)FROM bus_station_group_members`).
		WithArgs([]string{"G-1"}).
		WillReturnRows(pgxmock.NewRows([]string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}).
			AddRow("bus_route", "R-1", "307", "Taipei", "A", "B", nil, nil).
			CloseError(wantErr))

	results, err := expandStationRoutes(context.Background(), []searchResult{{Type: "bus_station", UID: "G-1"}}, db)
	if !errors.Is(err, wantErr) {
		t.Fatalf("err = %v, want %v", err, wantErr)
	}
	if results != nil {
		t.Fatalf("results = %#v, want nil to prevent partial results", results)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestHandleSearchDegradesOnVectorScanError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"embeddings":[[1,2]]}`))
	}))
	defer upstream.Close()
	t.Setenv("EMBED_URL", upstream.URL)

	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "台北", textSearchBranchLimit(20), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns))
	db.ExpectQuery(`(?s)FROM search_vector.*ORDER BY embedding`).
		WithArgs("[1,2]", 20).
		WillReturnRows(pgxmock.NewRows([]string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}).
			AddRow(struct{}{}, "uid", "name", "city", "depart", "destin", nil, nil))

	got := performSearchRequest(t, db, "台北")
	if got.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s, want 200", got.Code, got.Body.String())
	}
	if body := got.Body.String(); !strings.Contains(body, `"results":[]`) {
		t.Fatalf("body = %s, want empty results", body)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestTrainNumberSearchRejectsPartialRows(t *testing.T) {
	rowsErr := errors.New("train rows failed")
	tests := []struct {
		name string
		rows *pgxmock.Rows
		err  error
	}{
		{
			name: "scan error",
			rows: pgxmock.NewRows([]string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}).
				AddRow("tra_train", "1234", "1234", "", "A", "B", nil, nil).
				AddRow(struct{}{}, "5678", "5678", "", "A", "B", nil, nil),
		},
		{
			name: "rows error",
			rows: pgxmock.NewRows([]string{"type", "uid", "name", "city", "depart", "destin", "lat", "lon"}).
				AddRow("tra_train", "1234", "1234", "", "A", "B", nil, nil).
				CloseError(rowsErr),
			err: rowsErr,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			db.ExpectQuery(`(?s)FROM search_vector.*type IN`).WithArgs("1234").WillReturnRows(tt.rows)

			results, err := trainNumberSearch(context.Background(), "1234", db)
			if err == nil {
				t.Fatalf("results = %#v, want error", results)
			}
			if tt.err != nil && !errors.Is(err, tt.err) {
				t.Fatalf("err = %v, want %v", err, tt.err)
			}
			if results != nil {
				t.Fatalf("results = %#v, want nil to prevent partial results", results)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestHandleSearchFailsWhenRouteExpansionFails(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "台北車站", textSearchBranchLimit(20), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_station", "G-1", "台北車站", "Taipei", "", "", nil, nil, 0, 1.0))
	db.ExpectQuery(`(?s)FROM bus_station_group_members`).
		WithArgs([]string{"G-1"}).
		WillReturnError(errors.New("route expansion failed"))

	got := performSearchRequest(t, db, "台北車站")
	if got.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, body = %s, want 500", got.Code, got.Body.String())
	}
	if strings.Contains(got.Body.String(), "G-1") {
		t.Fatalf("body = %s, must not contain partial station result", got.Body.String())
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestIsNumericQuery(t *testing.T) {
	tests := []struct {
		name string
		q    string
		want bool
	}{
		{name: "empty", q: "", want: false},
		{name: "digits", q: "1234", want: true},
		{name: "route with letter", q: "307A", want: false},
		{name: "station", q: "台北", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isNumericQuery(tt.q); got != tt.want {
				t.Fatalf("isNumericQuery(%q) = %v, want %v", tt.q, got, tt.want)
			}
		})
	}
}

func TestShouldUseVector(t *testing.T) {
	tests := []struct {
		name string
		q    string
		want bool
	}{
		{name: "one rune", q: "北", want: false},
		{name: "station", q: "台北", want: true},
		{name: "numeric train", q: "1234", want: false},
		{name: "route code", q: "307A", want: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldUseVector(tt.q); got != tt.want {
				t.Fatalf("shouldUseVector(%q) = %v, want %v", tt.q, got, tt.want)
			}
		})
	}
}

func TestEmbeddingURLUsesEnvAndTrimSpace(t *testing.T) {
	t.Setenv("EMBED_URL", " http://embed:11434/api/embed ")
	if got := embeddingURL(); got != "http://embed:11434/api/embed" {
		t.Fatalf("embeddingURL() = %q", got)
	}
}

func TestEmbeddingURLEmptyDisablesVectorSearch(t *testing.T) {
	t.Setenv("EMBED_URL", "")
	if got := embeddingURL(); got != "" {
		t.Fatalf("embeddingURL() = %q, want empty", got)
	}
}

func TestMergeSearchResultsDedupesInPriorityOrder(t *testing.T) {
	train := []searchResult{
		{Type: "tra_train", UID: "1234", Name: "1234"},
	}
	text := []searchResult{
		{Type: "tra_train", UID: "1234", Name: "duplicate"},
		{Type: "bus_route", UID: "R1", Name: "307"},
	}
	vector := []searchResult{
		{Type: "bus_route", UID: "R1", Name: "duplicate route"},
		{Type: "mrt_station", UID: "BL12", Name: "台北車站"},
	}

	got := mergeSearchResults(10, train, text, vector)
	if len(got) != 3 {
		t.Fatalf("len = %d, want 3: %#v", len(got), got)
	}
	if got[0].Name != "1234" || got[1].Name != "307" || got[2].Name != "台北車站" {
		t.Fatalf("unexpected order: %#v", got)
	}
}

// textSearchWhereClauses splits _textSearchSQL into its WHERE clause bodies
// (one per branch), in source order, so tests can assert on each branch's
// predicate shape without depending on exact whitespace.
func textSearchWhereClauses(t *testing.T) []string {
	t.Helper()
	parts := strings.Split(_textSearchSQL, "WHERE")
	if len(parts) < 2 {
		t.Fatalf("textSearchSQL has no WHERE clauses: %s", _textSearchSQL)
	}
	var clauses []string
	for _, part := range parts[1:] {
		if idx := strings.Index(part, "ORDER BY"); idx >= 0 {
			part = part[:idx]
		}
		if idx := strings.Index(part, "LIMIT"); idx >= 0 {
			part = part[:idx]
		}
		clauses = append(clauses, strings.TrimSpace(part))
	}
	return clauses
}

func TestTextSearchExactUIDBranchIsIndexable(t *testing.T) {
	clauses := textSearchWhereClauses(t)
	if len(clauses) == 0 {
		t.Fatal("no WHERE clauses found")
	}
	exact := clauses[0]
	if exact != "uid = $1 AND ($3 = '' OR city = $3)" {
		t.Fatalf("exact branch WHERE = %q, want the uid = $1 equality ANDed with the city filter so it stays indexable", exact)
	}
}

func TestTextSearchBranchesAreCappedIndependently(t *testing.T) {
	clauses := textSearchWhereClauses(t)
	if len(clauses) != 3 {
		t.Fatalf("branch count = %d, want 3 (exact, prefix/trigram, contains): %#v", len(clauses), clauses)
	}
	if got := strings.Count(_textSearchSQL, "LIMIT $2"); got != 3 {
		t.Fatalf("LIMIT $2 occurrences = %d, want 3 (one per branch)", got)
	}
}

func TestTextSearchBranchesOrderBeforeCapping(t *testing.T) {
	rest := _textSearchSQL
	for branch := 0; ; branch++ {
		whereIdx := strings.Index(rest, "WHERE")
		if whereIdx < 0 {
			if branch != 3 {
				t.Fatalf("found %d branches, want 3", branch)
			}
			return
		}
		rest = rest[whereIdx+len("WHERE"):]
		limitIdx := strings.Index(rest, "LIMIT $2")
		if limitIdx < 0 {
			t.Fatalf("branch %d has no LIMIT $2 after its WHERE", branch)
		}
		branchBody := rest[:limitIdx]
		if !strings.Contains(branchBody, "ORDER BY") {
			t.Fatalf("branch %d applies LIMIT $2 without an ORDER BY, so the cap truncates in arbitrary scan order: %q", branch, strings.TrimSpace(branchBody))
		}
		rest = rest[limitIdx+len("LIMIT $2"):]
	}
}

func TestTextSearchHasNoSingleAllFieldsOrPredicate(t *testing.T) {
	clauses := textSearchWhereClauses(t)
	for i, clause := range clauses {
		fields := 0
		for _, f := range []string{"uid", "name", "depart", "destin"} {
			if strings.Contains(clause, f) {
				fields++
			}
		}
		if fields >= 4 {
			t.Fatalf("branch %d WHERE %q touches all %d fields via OR, want it split across branches", i, clause, fields)
		}
		if strings.Contains(clause, "uid") && (strings.Contains(clause, "depart") || strings.Contains(clause, "destin")) {
			t.Fatalf("branch %d WHERE %q ORs the indexable uid equality with the ILIKE columns, defeating index use", i, clause)
		}
	}
}

func TestTextSearchBranchLimitScalesWithoutExceedingCap(t *testing.T) {
	tests := []struct {
		name  string
		limit int
		want  int
	}{
		{name: "zero limit", limit: 0, want: 0},
		{name: "negative limit", limit: -1, want: 0},
		{name: "small limit scales", limit: 20, want: 100},
		{name: "large limit clamps to cap", limit: 50, want: _textSearchBranchCap},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := textSearchBranchLimit(tt.limit); got != tt.want {
				t.Fatalf("textSearchBranchLimit(%d) = %d, want %d", tt.limit, got, tt.want)
			}
		})
	}
}

func TestTextSearchDedupesDuplicateBranchHitsDeterministically(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// Simulate the same station reached through two branches: once via the
	// exact-uid branch (best rank 0) and once via the contains branch
	// (worse rank 5), plus an unrelated second result.
	db.ExpectQuery(`(?s)FROM search_vector.*WHERE uid = \$1`).
		WithArgs(pgx.QueryExecModeExec, "台北", textSearchBranchLimit(10), "").
		WillReturnRows(pgxmock.NewRows(_textSearchColumns).
			AddRow("bus_station", "S-1", "台北車站", "Taipei", "", "", nil, nil, 5, 0.4).
			AddRow("bus_station", "S-1", "台北車站", "Taipei", "", "", nil, nil, 0, 1.0).
			AddRow("bus_route", "R-2", "307", "Taipei", "A", "B", nil, nil, 4, 0.2))

	results, err := textSearch(context.Background(), "台北", "", 10, db)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 {
		t.Fatalf("results = %#v, want 2 deduped entries", results)
	}
	if results[0].UID != "S-1" || results[1].UID != "R-2" {
		t.Fatalf("results = %#v, want S-1 (best rank) before R-2", results)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestDedupeTextSearchCandidatesAppliesOneFinalCap(t *testing.T) {
	candidates := []textSearchCandidate{
		{result: searchResult{Type: "bus_route", UID: "1"}, rank: 0, sim: 1},
		{result: searchResult{Type: "bus_route", UID: "2"}, rank: 1, sim: 1},
		{result: searchResult{Type: "bus_route", UID: "3"}, rank: 2, sim: 1},
	}
	got := dedupeTextSearchCandidates(candidates, 2)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2 (final cap applied once): %#v", len(got), got)
	}
	if got[0].UID != "1" || got[1].UID != "2" {
		t.Fatalf("unexpected order after cap: %#v", got)
	}
}

func TestMergeSearchResultsHonorsLimit(t *testing.T) {
	got := mergeSearchResults(
		2,
		[]searchResult{
			{Type: "bus_route", UID: "1"},
			{Type: "bus_route", UID: "2"},
		},
		[]searchResult{{Type: "bus_route", UID: "3"}},
	)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2: %#v", len(got), got)
	}
}
