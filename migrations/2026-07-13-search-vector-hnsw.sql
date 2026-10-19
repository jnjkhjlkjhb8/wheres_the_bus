-- Speeds up the semantic-search fallback in services/router/search.go
-- (vectorSearch: ORDER BY embedding <=> $1::vector). Without this index the
-- query is a full sequential scan over search_vector computing cosine distance
-- per row. HNSW makes it approximate-nearest-neighbour instead.
--
-- Requires the vector extension (already used by the embedding column).
-- CONCURRENTLY avoids locking search_vector during the build; must run
-- outside a transaction block.

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_search_vector_embedding_hnsw
    ON search_vector USING hnsw (embedding vector_cosine_ops);
