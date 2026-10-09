#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: DATABASE_URL=... $0 migrations/<file>.sql" >&2
    exit 2
fi

file="$1"
if [ ! -f "$file" ]; then
    echo "apply-migration: $file does not exist" >&2
    exit 2
fi

: "${DATABASE_URL:?DATABASE_URL is required}"

name="$(basename "$file")"
checksum="$(sha256sum "$file" | awk '{print $1}')"
applied_by="${APPLIED_BY:-${USER:-unknown}}"

psql_args=(-X -v ON_ERROR_STOP=1)
if [ -n "${TARGET_SCHEMA:-}" ]; then
    psql_args+=(-v "target_schema=${TARGET_SCHEMA}")
fi

echo "== applying $name =="
psql "$DATABASE_URL" "${psql_args[@]}" -f "$file"

echo "== recording $name in schema_migrations =="
# Fed on stdin rather than with -c: psql only expands :'variables' when reading
# a file or stdin. A -c string must be parsable by the server as-is, so the
# same statement there fails with a syntax error at the first colon.
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
    -v "name=${name}" -v "checksum=${checksum}" -v "by=${applied_by}" <<'SQL'
INSERT INTO schema_migrations (filename, sha256, applied_by)
VALUES (:'name', :'checksum', :'by')
ON CONFLICT (filename) DO NOTHING;
SQL

echo "apply-migration: $name applied and recorded."
