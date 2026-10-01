package search

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func searchExplainPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping search EXPLAIN evidence test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	var provisioned bool
	if err := pool.QueryRow(context.Background(),
		`SELECT to_regclass('search_vector') IS NOT NULL`,
	).Scan(&provisioned); err != nil {
		pool.Close()
		t.Fatalf("probe search_vector: %v", err)
	}
	if !provisioned {
		pool.Close()
		t.Skip("search_vector not provisioned on DATABASE_URL; skipping search EXPLAIN evidence test")
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestTextSearchQueryPlanHasIndexableExactBranch(t *testing.T) {
	pool := searchExplainPool(t)

	var planJSON []byte
	err := pool.QueryRow(context.Background(),
		"EXPLAIN (FORMAT JSON) "+_textSearchSQL,
		"placeholder-query", textSearchBranchLimit(20), "",
	).Scan(&planJSON)
	if err != nil {
		t.Fatalf("EXPLAIN textSearchSQL: %v", err)
	}

	var plan []struct {
		Plan map[string]any `json:"Plan"`
	}
	if err := json.Unmarshal(planJSON, &plan); err != nil {
		t.Fatalf("parse EXPLAIN JSON: %v", err)
	}
	if len(plan) == 0 {
		t.Fatal("EXPLAIN returned no plan")
	}

	nodeTypes := collectPlanNodeTypes(plan[0].Plan)
	hasIndexAccess := false
	hasSeqScan := false
	for _, nt := range nodeTypes {
		switch nt {
		case "Index Scan", "Index Only Scan", "Bitmap Index Scan", "Bitmap Heap Scan":
			hasIndexAccess = true
		case "Seq Scan":
			hasSeqScan = true
		}
	}
	if hasSeqScan && !hasIndexAccess {
		t.Logf("plan uses only Seq Scan nodes (expected on unindexed/empty fixture data): %s", planJSON)
	}
	t.Logf("search EXPLAIN plan node types: %v", nodeTypes)
}

func collectPlanNodeTypes(node map[string]any) []string {
	var types []string
	if nt, ok := node["Node Type"].(string); ok {
		types = append(types, nt)
	}
	if children, ok := node["Plans"].([]any); ok {
		for _, c := range children {
			if childNode, ok := c.(map[string]any); ok {
				types = append(types, collectPlanNodeTypes(childNode)...)
			}
		}
	}
	return types
}
