#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

IMAGE="pgvector/pgvector:pg16"
CONTAINER="bus-check-migration-catalog-$$"
PORT="${CHECK_MIGRATION_CATALOG_PORT:-15434}"
DB=migcatalog
USER=postgres
PASS=postgres
SCHEMA=catalogtest

NEW_MIGRATIONS=(
  "migrations/2026-07-16-search-vector-hnsw-dedupe.sql"
  "migrations/2026-07-16-bus-schedule-scan-index.sql"
  "migrations/2026-07-16-tra-fk-indexes.sql"
)

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

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

psql() {
  docker exec -i -e PGOPTIONS="-c search_path=$SCHEMA,public" "$CONTAINER" \
    env PGPASSWORD="$PASS" psql -X -v ON_ERROR_STOP=1 -U "$USER" -d "$DB" "$@"
}

# scalar runs a query and returns its single result value as text.
scalar() { psql -A -t -c "$1"; }

echo "== provisioning fixture schema + extensions =="
docker exec -i "$CONTAINER" env PGPASSWORD="$PASS" \
  psql -X -v ON_ERROR_STOP=1 -U "$USER" -d "$DB" \
  -c "CREATE SCHEMA IF NOT EXISTS $SCHEMA;" \
  -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null

echo "== seeding fixture: search_vector with a duplicate HNSW pair =="
psql <<SQL >/dev/null
CREATE TABLE search_vector (
    id text PRIMARY KEY,
    name text,
    depart text,
    destin text,
    embedding vector(3)
);
INSERT INTO search_vector (id, name, depart, destin, embedding)
VALUES
    ('a', 'Stop A', 'A', 'B', '[0.1,0.2,0.3]'),
    ('b', 'Stop B', 'B', 'C', '[0.4,0.5,0.6]');

-- The migration-tracked index (as created by 2026-07-13-search-vector-hnsw.sql).
CREATE INDEX idx_search_vector_embedding_hnsw
    ON search_vector USING hnsw (embedding vector_cosine_ops);

-- The audit's second finding: a semantically identical HNSW index applied
-- out of band under a different name.
CREATE INDEX idx_search_vector_embedding_hnsw_legacy
    ON search_vector USING hnsw (embedding vector_cosine_ops);
SQL

echo "== seeding fixture: bus_schedule with circular-route duplicate keys =="
psql <<SQL >/dev/null
CREATE TABLE bus_schedule (
    sub_route_uid text,
    direction smallint,
    type bool,
    tripid text,
    islowfloor bool,
    stopsequence smallint,
    "stop_uid/MinHeadwayMins" text,
    "stop_name/MaxHeadwayMins" text,
    "arrival_time/StartTime" time,
    "departure_time/EndTime" time,
    service_day smallint,
    updated_at timestamptz NOT NULL DEFAULT NOW()
);

-- Same natural key (sub_route_uid, direction, type, service_day, tripid,
-- stop_uid/MinHeadwayMins), different stop position: a circular route
-- visiting the same stop twice on one trip. This is the exact shape
-- 2026-07-15-bus-static-contract-fixes.sql documents as intentional.
INSERT INTO bus_schedule
    (sub_route_uid, direction, type, tripid, stopsequence,
     "stop_uid/MinHeadwayMins", service_day)
VALUES
    ('R1', 0, true, 'T1', 1, 'STOP-X', 1),
    ('R1', 0, true, 'T1', 9, 'STOP-X', 1);
SQL

echo "== seeding fixture: tra_fares / tra_timetable without FK-supporting indexes =="
psql <<SQL >/dev/null
CREATE TABLE tra_fares (
    origin_station_id text,
    destination_station_id text,
    ticket_type text,
    price int,
    updated_at timestamptz NOT NULL DEFAULT NOW()
);
INSERT INTO tra_fares (origin_station_id, destination_station_id, ticket_type, price)
VALUES ('1000', '1010', 'adult', 100);

CREATE TABLE tra_timetable (
    train_date date NOT NULL,
    trainno text NOT NULL,
    direction integer,
    starting_station_id text NOT NULL,
    starting_station_name text NOT NULL,
    ending_station_id text NOT NULL,
    ending_station_name text NOT NULL,
    stationid text,
    stationname text,
    arrivaltime time,
    departuretime time,
    updated_at timestamptz NOT NULL DEFAULT NOW()
);
INSERT INTO tra_timetable
    (train_date, trainno, starting_station_id, starting_station_name,
     ending_station_id, ending_station_name, stationid)
VALUES ('2026-07-16', '101', '1000', 'A', '1010', 'B', '1000');
SQL

fail=0

echo
echo "== RED: pre-migration state must match the live audit findings =="

hnsw_count_pre="$(scalar "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam JOIN pg_namespace n ON n.oid = c.relnamespace WHERE i.indrelid = '${SCHEMA}.search_vector'::regclass AND am.amname = 'hnsw' AND i.indisvalid;")"
echo "  search_vector HNSW index count (expect 2, duplicate present) : $hnsw_count_pre"
if [ "$hnsw_count_pre" != "2" ]; then
  echo "  RED-CHECK FAIL: fixture did not reproduce the duplicate-HNSW finding"
  fail=1
fi

fk_idx_count_pre="$(scalar "SELECT count(*) FROM pg_indexes WHERE schemaname = '${SCHEMA}' AND indexname IN ('idx_tra_fares_destination_station_id','idx_tra_timetable_starting_station_id','idx_tra_timetable_ending_station_id');")"
echo "  tra FK supporting indexes present (expect 0) : $fk_idx_count_pre"
if [ "$fk_idx_count_pre" != "0" ]; then
  echo "  RED-CHECK FAIL: fixture already has the FK indexes before migration"
  fail=1
fi

bus_dupe_count_pre="$(scalar "SELECT count(*) FROM bus_schedule WHERE sub_route_uid='R1' AND direction=0 AND type=true AND tripid='T1' AND \"stop_uid/MinHeadwayMins\"='STOP-X';")"
echo "  bus_schedule circular-duplicate rows (expect 2) : $bus_dupe_count_pre"
if [ "$bus_dupe_count_pre" != "2" ]; then
  echo "  RED-CHECK FAIL: fixture did not reproduce the circular-duplicate finding"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "check-migration-catalog: FAIL (fixture setup does not match expected RED state)"
  exit 1
fi
echo "  RED confirmed: fixture reproduces both audit findings before any new migration runs."

apply_new_migrations() {
  local label="$1"
  echo
  echo "== applying new migrations ($label) =="
  for f in "${NEW_MIGRATIONS[@]}"; do
    name="$(basename "$f")"
    set +e
    out="$(psql < "$f" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      echo "  OK        $name"
    else
      echo "  FAIL      $name"
      echo "$out" | sed 's/^/            /'
      fail=1
    fi
  done
}

apply_new_migrations "first pass"

if [ "$fail" -ne 0 ]; then
  echo
  echo "check-migration-catalog: FAIL (a new migration errored on first apply)"
  exit 1
fi

echo
echo "== GREEN: post-migration catalog assertions =="

hnsw_count_post="$(scalar "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam JOIN pg_namespace n ON n.oid = c.relnamespace WHERE i.indrelid = '${SCHEMA}.search_vector'::regclass AND am.amname = 'hnsw' AND i.indisvalid;")"
echo "  search_vector valid HNSW index count (want 1) : $hnsw_count_post"
[ "$hnsw_count_post" = "1" ] || { echo "  GREEN-CHECK FAIL: duplicate HNSW index was not resolved to exactly one"; fail=1; }

remaining_hnsw_name="$(scalar "SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam JOIN pg_namespace n ON n.oid = c.relnamespace WHERE i.indrelid = '${SCHEMA}.search_vector'::regclass AND am.amname = 'hnsw' AND i.indisvalid;")"
echo "  surviving HNSW index (want idx_search_vector_embedding_hnsw) : $remaining_hnsw_name"
[ "$remaining_hnsw_name" = "idx_search_vector_embedding_hnsw" ] || { echo "  GREEN-CHECK FAIL: unexpected survivor selected by default rule"; fail=1; }

fk_idx_count_post="$(scalar "SELECT count(*) FROM pg_indexes WHERE schemaname = '${SCHEMA}' AND indexname IN ('idx_tra_fares_destination_station_id','idx_tra_timetable_starting_station_id','idx_tra_timetable_ending_station_id');")"
echo "  tra FK supporting indexes present (want 3) : $fk_idx_count_post"
[ "$fk_idx_count_post" = "3" ] || { echo "  GREEN-CHECK FAIL: not all three FK supporting indexes were created"; fail=1; }

bus_dupe_count_post="$(scalar "SELECT count(*) FROM bus_schedule WHERE sub_route_uid='R1' AND direction=0 AND type=true AND tripid='T1' AND \"stop_uid/MinHeadwayMins\"='STOP-X';")"
echo "  bus_schedule circular-duplicate rows preserved (want 2) : $bus_dupe_count_post"
[ "$bus_dupe_count_post" = "2" ] || { echo "  GREEN-CHECK FAIL: circular-duplicate rows were dropped by a migration"; fail=1; }

bus_unique_constraint_count="$(scalar "SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = c.conrelid) WHERE c.conrelid = '${SCHEMA}.bus_schedule'::regclass AND c.contype = 'u';")"
echo "  bus_schedule UNIQUE constraints (want 0) : $bus_unique_constraint_count"
[ "$bus_unique_constraint_count" = "0" ] || { echo "  GREEN-CHECK FAIL: a UNIQUE constraint was reintroduced on bus_schedule"; fail=1; }

scan_idx_unique="$(scalar "SELECT i.indisunique::text FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 'bus_schedule_scan_idx' AND i.indrelid = '${SCHEMA}.bus_schedule'::regclass;")"
echo "  bus_schedule_scan_idx exists and is non-unique (want false) : $scan_idx_unique"
[ "$scan_idx_unique" = "false" ] || { echo "  GREEN-CHECK FAIL: bus_schedule_scan_idx missing or unique"; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo
  echo "check-migration-catalog: FAIL (GREEN assertions did not hold after first apply)"
  exit 1
fi

apply_new_migrations "idempotent rerun"

if [ "$fail" -ne 0 ]; then
  echo
  echo "check-migration-catalog: FAIL (a new migration errored on rerun; not idempotent)"
  exit 1
fi

hnsw_count_rerun="$(scalar "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam JOIN pg_namespace n ON n.oid = c.relnamespace WHERE i.indrelid = '${SCHEMA}.search_vector'::regclass AND am.amname = 'hnsw' AND i.indisvalid;")"
fk_idx_count_rerun="$(scalar "SELECT count(*) FROM pg_indexes WHERE schemaname = '${SCHEMA}' AND indexname IN ('idx_tra_fares_destination_station_id','idx_tra_timetable_starting_station_id','idx_tra_timetable_ending_station_id');")"
bus_dupe_count_rerun="$(scalar "SELECT count(*) FROM bus_schedule WHERE sub_route_uid='R1' AND direction=0 AND type=true AND tripid='T1' AND \"stop_uid/MinHeadwayMins\"='STOP-X';")"

echo
echo "== state after idempotent rerun =="
echo "  search_vector valid HNSW index count : $hnsw_count_rerun"
echo "  tra FK supporting indexes present    : $fk_idx_count_rerun"
echo "  bus_schedule circular-duplicate rows : $bus_dupe_count_rerun"

[ "$hnsw_count_rerun" = "1" ] || { echo "  RERUN-CHECK FAIL: HNSW count drifted after rerun"; fail=1; }
[ "$fk_idx_count_rerun" = "3" ] || { echo "  RERUN-CHECK FAIL: FK index count drifted after rerun"; fail=1; }
[ "$bus_dupe_count_rerun" = "2" ] || { echo "  RERUN-CHECK FAIL: bus_schedule duplicate rows drifted after rerun"; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo
  echo "check-migration-catalog: FAIL (state drifted on idempotent rerun)"
  exit 1
fi

echo
echo "== scenario: HNSW dedupe with THREE identical indexes + typo'd survivor =="

SCHEMA2=catalogtest_hnsw3

# psql wrapper scoped to the second fixture schema; extra args (e.g. -v
# survivor_index=...) pass through.
psql2() {
  docker exec -i -e PGOPTIONS="-c search_path=$SCHEMA2,public" "$CONTAINER" \
    env PGPASSWORD="$PASS" psql -X -v ON_ERROR_STOP=1 -U "$USER" -d "$DB" "$@"
}
scalar2() { psql2 -A -t -c "$1"; }

docker exec -i "$CONTAINER" env PGPASSWORD="$PASS" \
  psql -X -v ON_ERROR_STOP=1 -U "$USER" -d "$DB" \
  -c "CREATE SCHEMA IF NOT EXISTS $SCHEMA2;" >/dev/null

psql2 <<SQL >/dev/null
CREATE TABLE search_vector (
    id text PRIMARY KEY,
    embedding vector(3)
);
INSERT INTO search_vector (id, embedding) VALUES ('a', '[0.1,0.2,0.3]');
CREATE INDEX idx_search_vector_embedding_hnsw
    ON search_vector USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_search_vector_embedding_hnsw_legacy1
    ON search_vector USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_search_vector_embedding_hnsw_legacy2
    ON search_vector USING hnsw (embedding vector_cosine_ops);
SQL

hnsw3_query="SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam WHERE i.indrelid = '${SCHEMA2}.search_vector'::regclass AND am.amname = 'hnsw' AND i.indisvalid;"

hnsw3_pre="$(scalar2 "$hnsw3_query")"
echo "  fixture HNSW index count (expect 3) : $hnsw3_pre"
[ "$hnsw3_pre" = "3" ] || { echo "  SCENARIO-CHECK FAIL: 3-duplicate fixture not seeded"; fail=1; }

echo "  -- typo'd survivor_index must fail before dropping anything --"
set +e
typo_out="$(psql2 -v survivor_index=idx_search_vector_embedding_hnsw_typo \
  < migrations/2026-07-16-search-vector-hnsw-dedupe.sql 2>&1)"
typo_rc=$?
set -e
echo "  exit code (want non-zero) : $typo_rc"
if [ "$typo_rc" -eq 0 ]; then
  echo "  SCENARIO-CHECK FAIL: typo'd survivor_index was silently accepted"
  fail=1
fi
if ! echo "$typo_out" | grep -q 'does not name a valid HNSW index'; then
  echo "  SCENARIO-CHECK FAIL: typo'd survivor_index error message missing"
  echo "$typo_out" | sed 's/^/            /'
  fail=1
fi
hnsw3_after_typo="$(scalar2 "$hnsw3_query")"
echo "  HNSW index count after failed typo run (want 3, nothing dropped) : $hnsw3_after_typo"
[ "$hnsw3_after_typo" = "3" ] || { echo "  SCENARIO-CHECK FAIL: typo run dropped an index"; fail=1; }

echo "  -- run 1 (no survivor override): drops one duplicate, NOTICEs about rerun --"
set +e
run1_out="$(psql2 < migrations/2026-07-16-search-vector-hnsw-dedupe.sql 2>&1)"
run1_rc=$?
set -e
echo "  exit code (want 0) : $run1_rc"
[ "$run1_rc" -eq 0 ] || { echo "  SCENARIO-CHECK FAIL: run 1 errored with duplicates remaining"; echo "$run1_out" | sed 's/^/            /'; fail=1; }
if ! echo "$run1_out" | grep -q 'rerun this migration to drop the next duplicate'; then
  echo "  SCENARIO-CHECK FAIL: run 1 did not emit the rerun NOTICE"
  echo "$run1_out" | sed 's/^/            /'
  fail=1
fi
hnsw3_run1="$(scalar2 "$hnsw3_query")"
echo "  HNSW index count after run 1 (want 2) : $hnsw3_run1"
[ "$hnsw3_run1" = "2" ] || { echo "  SCENARIO-CHECK FAIL: run 1 did not drop exactly one duplicate"; fail=1; }

echo "  -- run 2: drops the remaining duplicate, no rerun NOTICE --"
set +e
run2_out="$(psql2 < migrations/2026-07-16-search-vector-hnsw-dedupe.sql 2>&1)"
run2_rc=$?
set -e
echo "  exit code (want 0) : $run2_rc"
[ "$run2_rc" -eq 0 ] || { echo "  SCENARIO-CHECK FAIL: run 2 errored"; echo "$run2_out" | sed 's/^/            /'; fail=1; }
if echo "$run2_out" | grep -q 'rerun this migration to drop the next duplicate'; then
  echo "  SCENARIO-CHECK FAIL: run 2 still emitted the rerun NOTICE"
  fail=1
fi
hnsw3_run2="$(scalar2 "$hnsw3_query")"
echo "  HNSW index count after run 2 (want 1) : $hnsw3_run2"
[ "$hnsw3_run2" = "1" ] || { echo "  SCENARIO-CHECK FAIL: run 2 did not converge to one index"; fail=1; }

hnsw3_survivor="$(scalar2 "SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam WHERE i.indrelid = '${SCHEMA2}.search_vector'::regclass AND am.amname = 'hnsw' AND i.indisvalid;")"
echo "  survivor (want idx_search_vector_embedding_hnsw) : $hnsw3_survivor"
[ "$hnsw3_survivor" = "idx_search_vector_embedding_hnsw" ] || { echo "  SCENARIO-CHECK FAIL: default rule kept the wrong survivor"; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo
  echo "check-migration-catalog: FAIL (3-duplicate / typo'd-survivor scenario did not hold)"
  exit 1
fi

echo
echo "check-migration-catalog: PASS (RED reproduced the audit findings; GREEN holds after apply, after an idempotent rerun, and across the 3-duplicate + typo'd-survivor scenarios)"
