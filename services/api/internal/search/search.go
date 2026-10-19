// Package search answers place and stop lookups: full-text and phonetic search
// over the landed search_vector rows, plus forward geocoding through MOTIS.
// Both are read-only and cached in front.
package search

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
	"go.uber.org/zap"
)

const (
	_maxSearchQueryRunes  = 128
	_searchRequestTimeout = 5 * time.Second

	_maxSearchCityRunes = 32

	_searchCacheTTL = 10 * time.Minute

	// _searchCacheMaxEntries bounds the response cache. Keys are user query
	// text, so the keyspace is unbounded and the cache must be too.
	_searchCacheMaxEntries = 500

	_textSearchBranchCap = 200

	// _textSearchBranchScale sizes the per-branch cap relative to the
	// caller's limit so small requests don't pull _textSearchBranchCap rows
	// per branch; it's clamped to _textSearchBranchCap either way.
	_textSearchBranchScale = 5
)

// Capping each UNION branch preserves indexable scans.
const _textSearchSQL = `
SELECT type, uid, name, city, depart, destin, ST_Y(geom), ST_X(geom),
       CASE
         WHEN uid = $1 THEN 0
         WHEN name = $1 THEN 1
         WHEN name ILIKE $1 || '%' THEN 2
         WHEN name % $1 THEN 3
         WHEN depart ILIKE '%' || $1 || '%'
           OR destin ILIKE '%' || $1 || '%' THEN 4
         ELSE 5
       END AS rank,
       similarity(name, $1) AS sim
FROM (
    (SELECT type, uid, name, city, depart, destin, geom
     FROM search_vector
     WHERE uid = $1 AND ($3 = '' OR city = $3)
     ORDER BY uid ASC
     LIMIT $2)
  UNION ALL
    (SELECT type, uid, name, city, depart, destin, geom
     FROM search_vector
     WHERE (name ILIKE $1 || '%' OR name % $1) AND ($3 = '' OR city = $3)
     ORDER BY similarity(name, $1) DESC, name ASC, uid ASC
     LIMIT $2)
  UNION ALL
    (SELECT type, uid, name, city, depart, destin, geom
     FROM search_vector
     WHERE (name ILIKE '%' || $1 || '%'
        OR depart ILIKE '%' || $1 || '%'
        OR destin ILIKE '%' || $1 || '%') AND ($3 = '' OR city = $3)
     ORDER BY similarity(name, $1) DESC, name ASC, uid ASC
     LIMIT $2)
) candidates
ORDER BY rank, sim DESC, name ASC`

// textSearchBranchLimit bounds the per-branch row cap in _textSearchSQL. It
// scales with the caller's requested limit so small requests scan less, but
// never exceeds _textSearchBranchCap regardless of the requested limit.
func textSearchBranchLimit(limit int) int {
	if limit <= 0 {
		return 0
	}
	if scaled := limit * _textSearchBranchScale; scaled > 0 && scaled < _textSearchBranchCap {
		return scaled
	}
	return _textSearchBranchCap
}

type searchDB interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

type searchResult struct {
	Type   string   `json:"type"`
	UID    string   `json:"uid"`
	Name   string   `json:"name"`
	City   string   `json:"city"`
	Depart string   `json:"depart"`
	Destin string   `json:"destin"`
	Lat    *float64 `json:"lat"`
	Lon    *float64 `json:"lon"`
}

type searchQuery struct {
	text  string
	city  string
	limit int
}

func parseSearchQuery(c *gin.Context) (searchQuery, error) {
	query := searchQuery{text: strings.TrimSpace(c.Query("q")), city: strings.TrimSpace(c.Query("city")), limit: 20}
	if err := validateSearchQuery(query); err != nil {
		return query, err
	}
	query.limit = searchLimit(c.Query("limit"))
	return query, nil
}

func validateSearchQuery(query searchQuery) error {
	if query.text == "" {
		return errors.New("q required")
	}
	if utf8.RuneCountInString(query.text) > _maxSearchQueryRunes {
		return errors.New("q too long")
	}
	if utf8.RuneCountInString(query.city) > _maxSearchCityRunes {
		return errors.New("city too long")
	}
	return nil
}

func searchLimit(raw string) int {
	if limit, err := strconv.Atoi(raw); err == nil && limit > 0 && limit <= 50 {
		return limit
	}
	return 20
}

func HandleSearch(db searchDB) gin.HandlerFunc {
	responses := cache.NewBoundedTTLCache(_searchCacheMaxEntries)
	return func(c *gin.Context) {
		query, err := parseSearchQuery(c)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		key := searchCacheKey(query.text, query.city, query.limit)
		if data, ok := responses.Get(key); ok {
			c.Data(http.StatusOK, "application/json; charset=utf-8", data)
			return
		}
		serveFreshSearch(c, query, key, responses, db)
	}
}

func serveFreshSearch(c *gin.Context, query searchQuery, key string, responses *cache.TTLCache, db searchDB) {
	ctx, cancel := context.WithTimeout(c.Request.Context(), _searchRequestTimeout)
	defer cancel()
	results, err := executeSearch(ctx, query, db)
	if err != nil {
		zap.S().Errorw("search failed", "component", "search", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "search failed"})
		return
	}
	body, err := json.Marshal(gin.H{"results": results})
	if err != nil {
		zap.S().Errorw("response encode failed", "component", "search", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "search failed"})
		return
	}
	responses.Set(key, body, _searchCacheTTL)
	c.Data(http.StatusOK, "application/json; charset=utf-8", body)
}

func executeSearch(ctx context.Context, query searchQuery, db searchDB) ([]searchResult, error) {
	trainResults, err := searchTrainResults(ctx, query, db)
	if err != nil {
		return nil, err
	}
	textResults, err := textSearch(ctx, query.text, query.city, query.limit, db)
	if err != nil {
		return nil, err
	}
	results := mergeSearchResults(query.limit, trainResults, textResults)
	results = searchVectorFallback(ctx, query, results, db)
	return expandSearchResults(ctx, query, results, db)
}

func expandSearchResults(ctx context.Context, query searchQuery, results []searchResult, db searchDB) ([]searchResult, error) {
	// A full page has no room for expanded routes, so avoid the second query.
	if len(results) < query.limit {
		expanded, err := expandStationRoutes(ctx, results, db)
		if err != nil {
			return nil, err
		}
		results = mergeSearchResults(query.limit, expanded)
	}
	return results, nil
}

func searchTrainResults(ctx context.Context, query searchQuery, db searchDB) ([]searchResult, error) {
	// Train rows have no city, so city-scoped searches must exclude them.
	if isNumericQuery(query.text) && query.city == "" {
		return trainNumberSearch(ctx, query.text, db)
	}
	return nil, nil
}

func searchVectorFallback(ctx context.Context, query searchQuery, results []searchResult, db searchDB) []searchResult {
	if !needsSearchVector(query, results) {
		return results
	}
	// An optional embedding failure must preserve an empty successful search.
	vectorResults, err := vectorSearch(ctx, query.text, query.limit, db)
	if err != nil {
		zap.S().Errorw("vector search failed", "component", "search", "err", err)
		return results
	}
	return mergeSearchResults(query.limit, results, vectorResults)
}

func needsSearchVector(query searchQuery, results []searchResult) bool {
	return len(results) == 0 && query.city == "" && shouldUseVector(query.text)
}

func toVecLiteral(v []float32) string {
	parts := make([]string, len(v))
	for i, f := range v {
		parts[i] = strconv.FormatFloat(float64(f), 'f', -1, 32)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func embeddingURL() string {
	return strings.TrimSpace(os.Getenv("EMBED_URL"))
}

var _embedClient = resty.New().SetHeader("Content-Type", "application/json")

func embedQuery(ctx context.Context, text string) ([]float32, error) {
	url := embeddingURL()
	if url == "" {
		return nil, _oops.Errorf("embedding disabled")
	}
	ctx, cancel := context.WithTimeout(ctx, _searchRequestTimeout)
	defer cancel()
	resp, err := _embedClient.R().
		SetContext(ctx).
		SetBody(map[string]any{
			"model": "qwen3-embedding:0.6b",
			"input": []string{text},
		}).
		Post(url)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	return decodeEmbeddingResponse(resp)
}

func decodeEmbeddingResponse(resp *resty.Response) ([]float32, error) {
	if resp.StatusCode() != 200 {
		return nil, _oops.With("status_code", resp.StatusCode()).With("body", resp.Body()).Errorf("embed")
	}
	var result struct {
		Embeddings [][]float32 `json:"embeddings"`
	}
	if err := json.Unmarshal(resp.Body(), &result); err != nil {
		return nil, _oops.Wrapf(err, "embed parse")
	}
	if len(result.Embeddings) == 0 {
		return nil, errors.New("embed parse: response carried no embedding")
	}
	return result.Embeddings[0], nil
}

func vectorSearch(ctx context.Context, q string, limit int, db searchDB) ([]searchResult, error) {
	if embeddingURL() == "" {
		return nil, nil
	}
	vec, embedErr := embedQuery(ctx, q)
	if embedErr != nil {
		return nil, embedErr
	}
	rows, err := db.Query(ctx, `
		SELECT type, uid, name, city, depart, destin,
		       ST_Y(geom), ST_X(geom)
		FROM search_vector
		ORDER BY embedding <=> $1::vector
		LIMIT $2`,
		toVecLiteral(vec), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collectSearchResults(rows)
}

func collectSearchResults(rows pgx.Rows) ([]searchResult, error) {
	var results []searchResult
	for rows.Next() {
		var r searchResult
		if err := rows.Scan(&r.Type, &r.UID, &r.Name, &r.City, &r.Depart, &r.Destin, &r.Lat, &r.Lon); err != nil {
			return nil, err
		}
		results = append(results, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return results, nil
}

// textSearchCandidate pairs a scanned row with the rank/similarity the
// database computed for it, so textSearch can dedupe and order candidates
// that the same row may have reached through more than one SQL branch.
type textSearchCandidate struct {
	result searchResult
	rank   int
	sim    float64
}

func textSearch(ctx context.Context, q, city string, limit int, db searchDB) ([]searchResult, error) {
	rows, err := db.Query(ctx, _textSearchSQL, pgx.QueryExecModeExec, q, textSearchBranchLimit(limit), city)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	candidates, err := collectTextSearchCandidates(rows)
	if err != nil {
		return nil, err
	}
	return dedupeTextSearchCandidates(candidates, limit), nil
}

func collectTextSearchCandidates(rows pgx.Rows) ([]textSearchCandidate, error) {
	var candidates []textSearchCandidate
	for rows.Next() {
		var c textSearchCandidate
		if err := rows.Scan(
			&c.result.Type, &c.result.UID, &c.result.Name, &c.result.City,
			&c.result.Depart, &c.result.Destin, &c.result.Lat, &c.result.Lon,
			&c.rank, &c.sim,
		); err != nil {
			return nil, err
		}
		candidates = append(candidates, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return candidates, nil
}

func dedupeTextSearchCandidates(candidates []textSearchCandidate, limit int) []searchResult {
	if limit <= 0 {
		return nil
	}
	sort.SliceStable(candidates, func(i, j int) bool { return textSearchCandidateBefore(candidates[i], candidates[j]) })
	accumulator := newSearchAccumulator(limit, len(candidates))
	for _, candidate := range candidates {
		if accumulator.append(candidate.result) {
			break
		}
	}
	return accumulator.results
}

func textSearchCandidateBefore(a, b textSearchCandidate) bool {
	if a.rank != b.rank {
		return a.rank < b.rank
	}
	if a.sim != b.sim {
		return a.sim > b.sim
	}
	return a.result.Name < b.result.Name
}

type searchAccumulator struct {
	limit   int
	seen    map[string]bool
	results []searchResult
}

func newSearchAccumulator(limit, capacity int) *searchAccumulator {
	return &searchAccumulator{limit: limit, seen: make(map[string]bool, capacity), results: make([]searchResult, 0, limit)}
}

func (a *searchAccumulator) append(result searchResult) bool {
	key := searchResultKey(result)
	if a.seen[key] {
		return false
	}
	a.seen[key] = true
	a.results = append(a.results, result)
	return len(a.results) >= a.limit
}

func (a *searchAccumulator) appendGroup(group []searchResult) bool {
	for _, result := range group {
		if a.append(result) {
			return true
		}
	}
	return false
}

func searchResultKey(r searchResult) string {
	return r.Type + ":" + r.UID
}

func mergeSearchResults(limit int, groups ...[]searchResult) []searchResult {
	if limit <= 0 {
		return nil
	}
	accumulator := newSearchAccumulator(limit, limit)
	for _, group := range groups {
		if accumulator.appendGroup(group) {
			return accumulator.results
		}
	}
	return accumulator.results
}

func expandStationRoutes(ctx context.Context, primary []searchResult, db searchDB) ([]searchResult, error) {
	groupUIDs, seen := stationRouteIdentities(primary)
	if len(groupUIDs) == 0 {
		return primary, nil
	}
	rows, err := db.Query(ctx, `
		SELECT sv.type, sv.uid, sv.name, sv.city, sv.depart, sv.destin,
		       ST_Y(sv.geom), ST_X(sv.geom)
		FROM bus_station_group_members bsgm
		JOIN bus_station_stop_map bssm
		  ON bssm.station_id = bsgm.station_uid
		JOIN search_vector sv
		  ON sv.uid = bssm.sub_route_uid AND sv.type = 'bus_route'
		WHERE bsgm.group_uid = ANY($1)`,
		groupUIDs,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results, err := collectSearchResults(rows)
	if err != nil {
		return nil, err
	}
	return appendStationRoutes(primary, results, seen), nil
}

func appendStationRoutes(primary, extra []searchResult, seen map[string]bool) []searchResult {
	for _, result := range extra {
		key := searchResultKey(result)
		if !seen[key] {
			primary = append(primary, result)
			seen[key] = true
		}
	}
	return primary
}

func stationRouteIdentities(primary []searchResult) ([]string, map[string]bool) {
	var groupUIDs []string
	seen := make(map[string]bool, len(primary))
	for _, r := range primary {
		seen[searchResultKey(r)] = true
		if r.Type == "bus_station" {
			groupUIDs = append(groupUIDs, r.UID)
		}
	}
	return groupUIDs, seen
}

func isNumericQuery(q string) bool {
	return q != "" && strings.IndexFunc(q, nonNumericQueryRune) == -1
}

func nonNumericQueryRune(r rune) bool { return r < '0' || r > '9' }

func shouldUseVector(q string) bool {
	return len([]rune(q)) >= 2 && !isNumericQuery(q)
}

func trainNumberSearch(ctx context.Context, q string, db searchDB) ([]searchResult, error) {
	rows, err := db.Query(ctx, `
		SELECT type, uid, name, city, depart, destin,
		       ST_Y(geom), ST_X(geom)
		FROM search_vector
		WHERE uid = $1 AND type IN ('tra_train', 'thsr_train')`,
		q,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collectSearchResults(rows)
}

// searchCacheKey identifies a rendered response by everything that shapes
// it. The separator cannot appear in a city code, so no (q, city) pair can
// collide with another.
func searchCacheKey(q, city string, limit int) string {
	return q + "\x00" + city + "\x00" + strconv.Itoa(limit)
}
