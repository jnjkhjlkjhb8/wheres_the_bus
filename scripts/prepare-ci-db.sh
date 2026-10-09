#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"
command -v psql >/dev/null 2>&1 || { echo 'prepare-ci-db: psql is required' >&2; exit 1; }
# target_schema: schema-aware migrations (e.g. 2026-07-17-db-service-roles.sql)
# refuse to run without it. There is one environment, so it is always public.
export PGOPTIONS="-c search_path=public"
psql_cmd=(psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -v target_schema=public)
"${psql_cmd[@]}" -f migrations/baseline/0000-baseline.sql >/dev/null
for migration in migrations/*.sql; do
  if head -n1 "$migration" | grep -q '^-- REPLAY: skip'; then continue; fi
  "${psql_cmd[@]}" -f "$migration" >/dev/null
done
"${psql_cmd[@]}" -c 'CREATE EXTENSION IF NOT EXISTS postgis' >/dev/null
echo 'prepare-ci-db: baseline, migrations, and PostGIS are ready'
