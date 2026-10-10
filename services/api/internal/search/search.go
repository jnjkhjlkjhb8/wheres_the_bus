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

func HandleSearch(db searchDB) gin.HandlerFunc {
	// One cache per handler, built when the routes are wired.
	cache := cache.NewBoundedTTLCache(_searchCacheMaxEntries)
	return func(c *gin.Context) {
		q := strings.TrimSpace(c.Query("q"))
		if len(q) == 0 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "q required"})
			return
		}
		if utf8.RuneCountInString(q) > _maxSearchQueryRunes {
			c.JSON(http.StatusBadRequest, gin.H{"error": "q too long"})
			return
		}
		city := strings.TrimSpace(c.Query("city"))
		if utf8.RuneCountInString(city) > _maxSearchCityRunes {
			c.JSON(http.StatusBadRequest, gin.H{"error": "city too long"})
			return
		}
		limit := 20
		if l, err := strconv.Atoi(c.Query("limit")); err == nil && l > 0 && l <= 50 {
			limit = l
		}
		key := searchCacheKey(q, city, limit)
		if data, ok := cache.Get(key); ok {
			c.Data(http.StatusOK, "application/json; charset=utf-8", data)
			return
		}
		ctx, cancel := context.WithTimeout(c.Request.Context(), _searchRequestTimeout)
		defer cancel()
		var trainResults []searchResult
		// A train number is not a city-scoped entity — search_vector carries
		// no city for tra_train/thsr_train rows — so a city filter excludes
		// trains rather than trying to place them in one.
		if isNumericQuery(q) && city == "" {
			var err error
			trainResults, err = trainNumberSearch(ctx, q, db)
			if err != nil {
				zap.S().Errorw("train number search failed", "component", "search", "err", err)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "search failed"})
				return
			}
		}
		textResults, err := textSearch(ctx, q, city, limit, db)
		if err != nil {
			zap.S().Errorw("error", "component", "search", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "search failed"})
			return
		}
		results := mergeSearchResults(limit, trainResults, textResults)
		if len(results) == 0 && city == "" && shouldUseVector(q) {
			// the fallback is a bonus on an already-empty result, so a
			// failing embedder or vector scan degrades to the empty
			// result instead of turning "no match" into a 500.
			vectorResults, err := vectorSearch(ctx, q, limit, db)
			if err != nil {
				zap.S().Errorw("vector search failed", "component", "search", "err", err)
			} else {
				results = mergeSearchResults(limit, results, vectorResults)
			}
		}
		// Expansion can only add rows, and the response is already capped at
		// limit, so a full page has no room for them — running the join
		// would spend a second round trip on results that get dropped.
		if len(results) < limit {
			expandedResults, err := expandStationRoutes(ctx, results, db)
			if err != nil {
				zap.S().Errorw("route expansion failed", "component", "search", "err", err)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "search failed"})
				return
			}
			results = mergeSearchResults(limit, expandedResults)
		}
		body, err := json.Marshal(gin.H{"results": results})
		if err != nil {
			zap.S().Errorw("response encode failed", "component", "search", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "search failed"})
			return
		}
		cache.Set(key, body, _searchCacheTTL)
		c.Data(http.StatusOK, "application/json; charset=utf-8", body)
	}
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
	return dedupeTextSearchCandidates(candidates, limit), nil
}

func dedupeTextSearchCandidates(candidates []textSearchCandidate, limit int) []searchResult {
	if limit <= 0 {
		return nil
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].rank != candidates[j].rank {
			return candidates[i].rank < candidates[j].rank
		}
		if candidates[i].sim != candidates[j].sim {
			return candidates[i].sim > candidates[j].sim
		}
		return candidates[i].result.Name < candidates[j].result.Name
	})
	seen := make(map[string]bool, len(candidates))
	results := make([]searchResult, 0, limit)
	for _, c := range candidates {
		key := searchResultKey(c.result)
		if seen[key] {
			continue
		}
		seen[key] = true
		results = append(results, c.result)
		if len(results) >= limit {
			break
		}
	}
	return results
}

func searchResultKey(r searchResult) string {
	return r.Type + ":" + r.UID
}

func mergeSearchResults(limit int, groups ...[]searchResult) []searchResult {
	if limit <= 0 {
		return nil
	}
	seen := make(map[string]bool, limit)
	merged := make([]searchResult, 0, limit)
	for _, group := range groups {
		for _, r := range group {
			key := searchResultKey(r)
			if seen[key] {
				continue
			}
			seen[key] = true
			merged = append(merged, r)
			if len(merged) >= limit {
				return merged
			}
		}
	}
	return merged
}

func expandStationRoutes(ctx context.Context, primary []searchResult, db searchDB) ([]searchResult, error) {
	var groupUIDs []string
	seen := make(map[string]bool, len(primary))
	for _, r := range primary {
		seen[searchResultKey(r)] = true
		if r.Type == "bus_station" {
			groupUIDs = append(groupUIDs, r.UID)
		}
	}
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
	var extra []searchResult
	for rows.Next() {
		var r searchResult
		if err := rows.Scan(&r.Type, &r.UID, &r.Name, &r.City, &r.Depart, &r.Destin, &r.Lat, &r.Lon); err != nil {
			return nil, err
		}
		key := searchResultKey(r)
		if !seen[key] {
			extra = append(extra, r)
			seen[key] = true
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return append(primary, extra...), nil
}

func isNumericQuery(q string) bool {
	if len(q) == 0 {
		return false
	}
	for _, c := range q {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

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

// searchCacheKey identifies a rendered response by everything that shapes
// it. The separator cannot appear in a city code, so no (q, city) pair can
// collide with another.
func searchCacheKey(q, city string, limit int) string {
	return q + "\x00" + city + "\x00" + strconv.Itoa(limit)
}
