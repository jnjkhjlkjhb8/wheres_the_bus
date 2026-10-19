-- FDPL-73: phonetic and shorthand search.
--
-- search_vector matched Chinese characters only, so a rider typing on a
-- pinyin or 注音 keyboard matched nothing until the IME committed. alias holds
-- the readings of name — full pinyin, its initials, toneless Bopomofo, and
-- hand-listed contractions such as 北車 — written by the loader's
-- changetovector stage (searchAlias in services/functions/search_alias.go).
--
-- Nullable, and left NULL until the next nightly load fills it: every
-- predicate in services/router/search.go's _textSearchSQL treats NULL as "no
-- match", so the column is inert between this migration and that load rather
-- than an error.
--
-- The trigram index mirrors the ones name/depart/destin already carry
-- (migrations/2026-06-14-perf-indexes.sql, 2026-07-03-db-health-indexes.sql):
-- the alias predicates are the same ILIKE-prefix / % / ILIKE-contains shapes,
-- and without it they are a sequential scan.
--
-- CONCURRENTLY avoids locking search_vector during the build; must run
-- outside a transaction block.

ALTER TABLE search_vector ADD COLUMN IF NOT EXISTS alias text;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_search_vector_alias_trgm
    ON search_vector USING gin (alias gin_trgm_ops);
