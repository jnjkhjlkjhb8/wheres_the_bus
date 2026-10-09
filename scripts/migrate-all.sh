#!/usr/bin/env bash
# Applies every migration not yet in schema_migrations, in filename order, the
# way the per-release migrate Job runs it (ADR-0027). Usage:
#   DATABASE_URL=... scripts/migrate-all.sh [migrations-dir]
#
# - A recorded file whose SHA-256 changed stops everything before any SQL runs:
#   CI tested the file as it is now, the database ran it as it was then.
# - One psql session holds an advisory lock for the whole batch, so a second
#   run (a retried Job, an operator) fails fast instead of interleaving.
# - lock_timeout keeps a migration from queueing behind live traffic: if it
#   cannot get its lock in 5 s it fails and the deploy stops.
set -euo pipefail

dir="${1:-migrations}"
: "${DATABASE_URL:?DATABASE_URL is required}"
lock_key=7094703426938431346 # "bus-migr" as a signed 64-bit int
psql_args=(-X -q -v ON_ERROR_STOP=1 -v target_schema=public)

sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

recorded="$(psql "$DATABASE_URL" "${psql_args[@]}" -At -F' ' -c 'SELECT filename, sha256 FROM schema_migrations')"

pending=()
for f in "$dir"/*.sql; do
    name="$(basename "$f")"
    want="$(sha "$f")"
    have="$(printf '%s\n' "$recorded" | awk -v n="$name" '$1 == n { print $2 }')"
    if [ -n "$have" ]; then
        if [ "$have" != "$want" ]; then
            echo "migrate-all: $name was applied with sha256 $have but the file is now $want; refusing to run" >&2
            exit 1
        fi
        continue
    fi
    # One-shot cleanups marked for replay skip never run on a database that
    # has not already recorded them.
    if head -n1 "$f" | grep -q '^-- REPLAY: skip'; then
        continue
    fi
    pending+=("$f")
done

if [ "${#pending[@]}" -eq 0 ]; then
    echo "migrate-all: nothing to apply"
    exit 0
fi

script="$(mktemp)"
trap 'rm -f "$script"' EXIT
{
    printf '%s\n' \
        "SET lock_timeout = '5s';" \
        "SET statement_timeout = '30min';" \
        "SELECT pg_try_advisory_lock($lock_key) AS locked \\gset" \
        '\if :locked' \
        '\else' \
        "  \\echo 'migrate-all: another migration run holds the lock'" \
        '  SELECT 1/0;' \
        '\endif'
    for f in "${pending[@]}"; do
        name="$(basename "$f")"
        printf '%s\n' \
            "\\echo '== applying $name'" \
            "\\i $f" \
            "INSERT INTO schema_migrations (filename, sha256, applied_by) VALUES ('$name', '$(sha "$f")', 'migrate-job') ON CONFLICT (filename) DO NOTHING;"
    done
    printf '%s\n' "SELECT pg_advisory_unlock($lock_key) AS unlocked \\gset"
} >"$script"
psql "$DATABASE_URL" "${psql_args[@]}" -f "$script"
echo "migrate-all: applied ${#pending[@]} file(s)"
