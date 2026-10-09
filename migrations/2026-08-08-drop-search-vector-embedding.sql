-- FDPL-74: remove the semantic-search fallback.
--
-- The embedding was only ever read by services/router/search.go's
-- vectorSearch, which ran solely when text search matched nothing. That
-- fallback is gone: FDPL-73's alias column answers the same need (a rider who
-- cannot yet type the Chinese name) by reading, at a fraction of the cost.
--
-- What this reclaims on the Azure B1ms (2 GB): a vector(1024) is ~4 KB per
-- row, and the HNSW graph is the same order again. Together they are the
-- largest single memory consumer on that instance.
--
-- Run FDPL-73's migration (2026-08-08-search-vector-alias.sql) and one
-- nightly load BEFORE this one. Until alias is populated, dropping embedding
-- leaves the phonetic path unpopulated and the semantic path gone.
--
-- The index is dropped first and CONCURRENTLY, so the drop does not hold an
-- ACCESS EXCLUSIVE lock on search_vector while it rewrites the graph; must
-- run outside a transaction block. DROP COLUMN itself is a catalog-only
-- operation and takes the lock only briefly.
--
-- Not reversible without re-embedding the whole corpus, which needs an
-- embedding service this deployment no longer runs.

DROP INDEX CONCURRENTLY IF EXISTS idx_search_vector_embedding_hnsw;

ALTER TABLE search_vector DROP COLUMN IF EXISTS embedding;
