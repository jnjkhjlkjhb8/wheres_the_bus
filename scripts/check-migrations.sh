#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "check-migrations: SKIPPED (docker not available in this environment; CI provides it)"
    exit 0
fi

# Same image the cluster runs (docker/postgres/Dockerfile): PG18 + PostGIS + pgvector.
IMAGE="bus-postgres:check-migrations"
CONTAINER="bus-check-migrations-$$"
PORT="${CHECK_MIGRATIONS_PORT:-15433}"
DB=migcheck
USER=postgres
PASS=postgres

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== building $IMAGE from docker/postgres =="
docker build -q -t "$IMAGE" docker/postgres >/dev/null

echo "== starting ephemeral postgres ($IMAGE) =="
docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD="$PASS" -e POSTGRES_USER="$USER" -e POSTGRES_DB="$DB" \
    -p "127.0.0.1:${PORT}:5432" "$IMAGE" >/dev/null

echo "== waiting for postgres to accept connections =="
for _ in $(seq 1 30); do
    if docker exec "$CONTAINER" pg_isready -U "$USER" -d "$DB" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$CONTAINER" pg_isready -U "$USER" -d "$DB" >/dev/null

psql_round() {
    local schema="$1" file="$2"
    docker exec -i -e PGOPTIONS="-c search_path=${schema},public" "$CONTAINER" \
        env PGPASSWORD="$PASS" psql -X -v ON_ERROR_STOP=1 \
        -v "target_schema=${schema}" \
        -U "$USER" -d "$DB" < "$file"
}

is_replay_skip() {
    head -n 1 "$1" | grep -qE '^-- REPLAY: skip'
}

fail=0

run_round() {
    local schema="$1"
    echo
    echo "== round: ${schema} =="

    if [ "$schema" != "public" ]; then
        echo "  -- creating schema ${schema} --"
        docker exec -i "$CONTAINER" env PGPASSWORD="$PASS" \
            psql -X -v ON_ERROR_STOP=1 -U "$USER" -d "$DB" \
            -c "CREATE SCHEMA IF NOT EXISTS ${schema};" >/dev/null
    fi

    echo "  -- baseline --"
    if ! out="$(psql_round "$schema" "migrations/baseline/0000-baseline.sql" 2>&1)"; then
        echo "  FAIL      baseline/0000-baseline.sql"
        echo "$out" | sed 's/^/            /'
        fail=1
        return
    fi
    echo "  OK        baseline/0000-baseline.sql"

    for f in migrations/*.sql; do
        name="$(basename "$f")"
        if is_replay_skip "$f"; then
            echo "  SKIP      $name (marked -- REPLAY: skip)"
            continue
        fi
        if ! out="$(psql_round "$schema" "$f" 2>&1)"; then
            echo "  FAIL      $name"
            echo "$out" | sed 's/^/            /'
            fail=1
            continue
        fi
        echo "  OK        $name"
    done
}

run_round "public"

echo
if [ "$fail" -ne 0 ]; then
    echo "check-migrations: FAIL (a migration failed to replay on an empty database; see FAIL entries above)"
    exit 1
fi

echo "check-migrations: PASS (baseline + full migration history replay cleanly on an empty database, public schema)"
