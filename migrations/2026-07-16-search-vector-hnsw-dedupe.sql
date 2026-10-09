-- Drops a semantically-duplicate HNSW index on search_vector.embedding.
--
-- Background: 2026-07-13-search-vector-hnsw.sql created
-- idx_search_vector_embedding_hnsw. The live schema audit found a second
-- HNSW index on the same table/column/opclass — created out of band,
-- directly against the live database, under a different name. Two HNSW
-- indexes over the same key give zero query benefit (only one is ever
-- chosen by the planner) and double the write-time cost of every embedding
-- upsert, since HNSW graph maintenance is not free.
--
-- This migration is defensive rather than name-based: it finds duplicates
-- by comparing pg_index/pg_opclass metadata (indkey, indclass,
-- indcollation, indoption, indpred) plus the access method, so it can never
-- mistake two HNSW indexes with different key definitions (e.g. a future
-- second HNSW index on a different column) for duplicates. It only ever
-- drops ONE duplicate per run; with three or more identical indexes the
-- final verification emits a NOTICE (not an error) telling the operator to
-- rerun, and each rerun removes the next duplicate until one remains.
--
-- The equivalence predicate deliberately ignores pg_class.reloptions
-- (HNSW build parameters: WITH (m = ..., ef_construction = ...)). Two
-- indexes that differ only in build parameters still index the same key
-- with the same opclass — the planner treats them interchangeably and one
-- is redundant, so they should still be deduplicated. Today this is moot:
-- the tracked index (2026-07-13-search-vector-hnsw.sql) was created with
-- defaults. If build parameters ever matter, pick the survivor explicitly
-- via survivor_index below instead of tightening the predicate.
--
-- Survivor selection: the caller may force a specific survivor with
--   psql -v survivor_index=<name> -f migrations/2026-07-16-search-vector-hnsw-dedupe.sql
-- A survivor_index that names no valid HNSW index on search_vector is an
-- error (fails before anything is dropped), so a typo cannot silently fall
-- back to the default rule. Absent an override, the safe default keeps
-- idx_search_vector_embedding_hnsw (the migration-tracked, documented
-- index) when it is part of the pair; otherwise it keeps the
-- first-created member (lowest oid).
--
-- Must run via psql, NOT wrapped in an explicit transaction:
-- DROP INDEX CONCURRENTLY cannot execute inside BEGIN/COMMIT or inside a
-- DO block/function body, so index discovery below uses psql's own
-- \gset/\if rather than PL/pgSQL.
--
-- Idempotent: once at most one HNSW index remains on search_vector, both
-- the detection query and the verification block are no-ops / pass.

\set ON_ERROR_STOP on

DO $schema_check$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'search_path must resolve a target schema; set PGOPTIONS=''-c search_path=<schema>'' before applying';
    END IF;
END
$schema_check$;

\if :{?survivor_index}
\else
    \set survivor_index _none_
\endif

-- Validate an explicit survivor_index before touching anything: a typo'd
-- name must fail loudly, not silently fall back to the default rule.
-- psql does not interpolate :variables inside dollar-quoted DO bodies, so
-- the value is passed through a session GUC instead.
SELECT set_config('migration.survivor_index', :'survivor_index', false) AS survivor_index_requested;

DO $survivor_check$
DECLARE
    survivor text := current_setting('migration.survivor_index', true);
    candidates text[];
BEGIN
    IF survivor IS NULL OR survivor = '_none_' THEN
        RETURN;
    END IF;

    SELECT array_agg(c.relname ORDER BY c.oid) INTO candidates
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam
     WHERE i.indrelid = 'search_vector'::regclass
       AND am.amname = 'hnsw'
       AND i.indisvalid;

    IF candidates IS NULL OR NOT survivor = ANY (candidates) THEN
        RAISE EXCEPTION
            'survivor_index "%" does not name a valid HNSW index on search_vector; valid candidates: %',
            survivor, coalesce(candidates::text, '(none)');
    END IF;
END
$survivor_check$;

WITH dupes AS (
    SELECT
        c1.relname AS name_a,
        c2.relname AS name_b
    FROM pg_index i1
    JOIN pg_index i2
      ON i1.indrelid = i2.indrelid
     AND i1.indexrelid < i2.indexrelid
    JOIN pg_class c1 ON c1.oid = i1.indexrelid
    JOIN pg_class c2 ON c2.oid = i2.indexrelid
    JOIN pg_am am1 ON am1.oid = c1.relam
    JOIN pg_am am2 ON am2.oid = c2.relam
    WHERE i1.indrelid = 'search_vector'::regclass
      AND am1.amname = 'hnsw'
      AND am2.amname = 'hnsw'
      AND i1.indkey = i2.indkey
      AND i1.indclass = i2.indclass
      AND i1.indcollation = i2.indcollation
      AND i1.indoption = i2.indoption
      AND coalesce(i1.indpred::text, '') = coalesce(i2.indpred::text, '')
      -- pg_class.reloptions (WITH m/ef_construction) intentionally not
      -- compared — see the header comment for why build-parameter-only
      -- differences still count as duplicates.
      AND i1.indisvalid
      AND i2.indisvalid
)
-- LEFT JOIN against a guaranteed single row so this always returns exactly
-- one row (with NULLs when no duplicate exists) instead of zero rows —
-- \gset errors out on a zero-row result, but silently unsets its target
-- variables for a NULL column value, which is what the \if below expects.
SELECT picked.keep_index, picked.drop_index
FROM (SELECT 1) AS one_row
LEFT JOIN (
    SELECT
        CASE
            WHEN :'survivor_index' <> '_none_' AND :'survivor_index' = name_a THEN name_a
            WHEN :'survivor_index' <> '_none_' AND :'survivor_index' = name_b THEN name_b
            WHEN name_a = 'idx_search_vector_embedding_hnsw' THEN name_a
            WHEN name_b = 'idx_search_vector_embedding_hnsw' THEN name_b
            ELSE name_a
        END AS keep_index,
        CASE
            WHEN :'survivor_index' <> '_none_' AND :'survivor_index' = name_a THEN name_b
            WHEN :'survivor_index' <> '_none_' AND :'survivor_index' = name_b THEN name_a
            WHEN name_a = 'idx_search_vector_embedding_hnsw' THEN name_b
            WHEN name_b = 'idx_search_vector_embedding_hnsw' THEN name_a
            ELSE name_b
        END AS drop_index
    FROM dupes
    LIMIT 1
) AS picked ON true
\gset dup_

\if :{?dup_drop_index}
    \echo Dropping semantic-duplicate HNSW index :dup_drop_index (keeping :dup_keep_index)
    DROP INDEX CONCURRENTLY IF EXISTS :dup_drop_index;
\else
    \echo No semantically duplicate HNSW index pair found on search_vector; nothing to do.
\endif

-- Verify: at least one valid HNSW index remains on search_vector (the
-- semantic-search read path in services/router/search.go depends on it).
-- More than one remaining is NOT an error — each run drops a single
-- duplicate, so with 3+ identical indexes the operator reruns this file
-- until one remains; a NOTICE says so.
DO $verify$
DECLARE
    remaining int;
BEGIN
    SELECT count(*) INTO remaining
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam
     WHERE i.indrelid = 'search_vector'::regclass
       AND am.amname = 'hnsw'
       AND i.indisvalid;

    IF remaining < 1 THEN
        RAISE EXCEPTION 'no valid HNSW index remains on search_vector; expected at least one';
    ELSIF remaining > 1 THEN
        RAISE NOTICE '% valid HNSW indexes still remain on search_vector; rerun this migration to drop the next duplicate', remaining;
    END IF;
END
$verify$;
