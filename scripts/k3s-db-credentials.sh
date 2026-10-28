#!/usr/bin/env bash
# Database logins for the k3s cluster (ADR-0026, ADR-0027). Passwords live only
# in the operator's env file and in the sealed Secrets; nothing is printed.
#
#   gen <env-file>
#       Gives every service its own login and points its URL at the cluster
#       PostgreSQL (<SERVICE>_DATABASE_URL, MIGRATE_DATABASE_URL, PS_*). Keeps
#       a password that is already in place, so it is safe to re-run.
#   prepare
#       Creates the `bus` and `powersync` databases and the powersync_svc
#       login (REPLICATION). Run before restoring the dump.
#   finish <env-file>
#       After the dump is restored: applies the service-roles migration and the
#       files Azure never received as the superuser, backfills schema_migrations
#       for the rest of the history Azure already reflects (the migrate Job runs
#       as a non-superuser and would otherwise replay it all), sets the passwords from
#       <env-file> and grants powersync_svc read access.
#   apply-superuser <migration>
#       Applies one migration that needs the superuser (the migrate Job runs as
#       bus_migrator) and records it in schema_migrations, so the Job skips it.
#   rotate <env-file> <secret-files-dir> <role>
#       New password for one login: rewrites its URLs in <env-file>, runs ALTER
#       ROLE, reseals and applies the Secrets, then restarts the Deployments
#       that use it. Connections opened between the ALTER and the restart are
#       refused, so rotate outside the nightly window. Rotate every login
#       yearly and whenever an env file or Secret may have leaked.
#
# SQL runs through `kubectl exec` as the postgres superuser on the Pod's local
# socket. PSQL_CMD overrides that (tests point it at a scratch server).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

INFRA_DIR="${INFRA_DIR:-$repo_root/../bus-infra}"
MIGRATION=2026-10-07-service-roles-k3s.sql
# The Azure database has no schema_migrations, and its schema already reflects
# every dated file up to AZURE_LAST except these, which never reached it
# (checked against the 2026-10-09 dump, FDPL-119/FDPL-120). finish applies them
# and records the rest without running them, so the migrate Job starts after
# AZURE_LAST instead of replaying history onto live data.
AZURE_LAST=2026-10-08-static-release-gtfs-rt-snapshot.sql
AZURE_MISSING="2026-07-30-drop-bus-eta-history.sql 2026-07-31-drop-bus-travel-avg.sql 2026-08-08-drop-unread-export-tables.sql 2026-08-21-drop-bike-availability-history.sql 2026-09-19-arrival-reminder-retention.sql 2026-10-08-route-alert-outbox.sql 2026-10-08-static-release-gtfs-rt-snapshot.sql"
# <env key>:<role>:<database>
URLS="API_DATABASE_URL:api_svc:bus REALTIME_DATABASE_URL:realtime_svc:bus RIDER_DATABASE_URL:rider_svc:bus PIPELINE_DATABASE_URL:pipeline_svc:bus MIGRATE_DATABASE_URL:bus_migrator:bus PS_SOURCE_DATABASE_URL:powersync_svc:bus PS_DATABASE_URL:powersync_svc:powersync"

die() { echo "k3s-db-credentials: $*" >&2; exit 1; }

read -r -a psql <<<"${PSQL_CMD:-kubectl -n bus exec -i postgres-0 -c postgres -- psql -U postgres -X -q -v ON_ERROR_STOP=1}"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

gen() {
    local env_file="$1"
    [ -f "$env_file" ] || die "env file not found: $env_file"
    cp -p "$env_file" "$env_file.bak-$(date +%Y%m%d%H%M%S)"
    python3 - "$env_file" "$URLS" <<'EOF'
import os, re, secrets, sys
path, spec = sys.argv[1], [s.split(":") for s in sys.argv[2].split()]
lines = open(path).read().splitlines()
vals = {l.split("=", 1)[0]: l.split("=", 1)[1] for l in lines if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", l)}
cluster = re.compile(r"^postgres://([^:/@]+):([0-9a-f]+)@postgres:5432/[^?]+\?sslmode=")
pw = {}
for key, role, _ in spec:
    m = cluster.match(vals.get(key, ""))
    if m and m.group(1) == role:
        pw.setdefault(role, m.group(2))
for _, role, _ in spec:
    pw.setdefault(role, secrets.token_hex(24))
# pg_hba.conf accepts the service logins over TLS only; the Pods mount bus-ca's
# certificate at /etc/bus-ca (PowerSync takes it from its own config instead).
new = {k: f"postgres://{r}:{pw[r]}@postgres:5432/{d}?sslmode=verify-full&sslrootcert=/etc/bus-ca/ca.crt" for k, r, d in spec}
changed, out, seen = [], [], set()
for l in lines:
    k = l.split("=", 1)[0]
    if k in new:
        seen.add(k)
        if l.split("=", 1)[1] != new[k]:
            changed.append(k)
        out.append(f"{k}={new[k]}")
    else:
        out.append(l)
for k in new:
    if k not in seen:
        out.append(f"{k}={new[k]}")
        changed.append(k)
open(path, "w").write("\n".join(out) + "\n")
os.chmod(path, 0o600)
print("k3s-db-credentials: updated " + (", ".join(changed) if changed else "nothing (already pointing at the cluster)"))
EOF
}

prepare() {
    "${psql[@]}" <<'EOF'
SELECT 'CREATE ROLE powersync_svc LOGIN REPLICATION'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powersync_svc') \gexec
ALTER ROLE powersync_svc LOGIN REPLICATION;
SELECT 'CREATE DATABASE bus'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'bus') \gexec
SELECT 'CREATE DATABASE powersync OWNER powersync_svc'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'powersync') \gexec
EOF
    echo "k3s-db-credentials: databases bus and powersync, role powersync_svc ready"
}

# apply_superuser <migration file>: applies it as the superuser once and records
# it in the ledger. The Azure dump carries no ledger, so the table is created
# first (the ledger migration is idempotent).
apply_superuser() {
    local file="$1" name applied
    name="$(basename "$file")"
    [ -f "$file" ] || die "$file not found (run from the repo)"
    "${psql[@]}" -d bus -v target_schema=public <migrations/2026-07-17-schema-migrations-ledger.sql >/dev/null
    applied="$("${psql[@]}" -d bus -At -c "SELECT 1 FROM schema_migrations WHERE filename = '$name'")"
    if [ -n "$applied" ]; then
        echo "k3s-db-credentials: $name already recorded; skipping"
        return
    fi
    "${psql[@]}" -d bus -v target_schema=public <"$file"
    "${psql[@]}" -d bus -c "INSERT INTO schema_migrations (filename, sha256, applied_by) VALUES ('$name', '$(sha "$file")', 'operator') ON CONFLICT (filename) DO NOTHING"
    echo "k3s-db-credentials: applied and recorded $name"
}

# backfill_ledger records every dated file up to AZURE_LAST that is not in the
# ledger yet, without running it.
backfill_ledger() {
    local f name
    for f in migrations/*.sql; do
        name="$(basename "$f")"
        [[ "$name" > "$AZURE_LAST" ]] && continue
        printf "INSERT INTO schema_migrations (filename, sha256, applied_by) VALUES ('%s', '%s', 'azure-backfill') ON CONFLICT (filename) DO NOTHING;\n" "$name" "$(sha "$f")"
    done | "${psql[@]}" -d bus
}

# The files applied above run as the superuser after 2026-10-07 has already
# moved ownership, so what they create (route_alert_outbox, static_release, ...)
# would stay owned by postgres and the migrate Job (bus_migrator) could not
# alter it later. Hand every table and standalone sequence to bus_migrator.
reown() {
    "${psql[@]}" -d bus <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname,
           CASE c.relkind WHEN 'S' THEN 'SEQUENCE' ELSE 'TABLE' END AS kind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'raw_tdx')
      AND c.relkind IN ('r', 'p', 'S')
      AND pg_get_userbyid(c.relowner) <> 'bus_migrator'
      AND NOT (n.nspname = 'public' AND c.relname = 'spatial_ref_sys')
      -- extension members stay with the extension
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
      -- a serial/identity sequence follows its table
      AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a', 'i')))
  LOOP
    EXECUTE format('ALTER %s %I.%I OWNER TO bus_migrator', r.kind, r.nspname, r.relname);
  END LOOP;
END
$$;
SQL
}

finish() {
    local env_file="$1" f
    [ -f "$env_file" ] || die "env file not found: $env_file"
    apply_superuser "migrations/$MIGRATION"
    for f in $AZURE_MISSING; do
        apply_superuser "migrations/$f"
    done
    reown
    backfill_ledger
    python3 - "$env_file" "$URLS" <<'EOF' | "${psql[@]}" -d bus
import re, sys
path, spec = sys.argv[1], [s.split(":") for s in sys.argv[2].split()]
vals = {l.split("=", 1)[0]: l.split("=", 1)[1] for l in open(path).read().splitlines() if "=" in l}
rx = re.compile(r"^postgres://([^:/@]+):([0-9a-f]+)@postgres:5432/")
done = set()
for key, role, _ in spec:
    m = rx.match(vals.get(key, ""))
    if not m or m.group(1) != role:
        sys.exit(f"{key} does not hold a cluster URL for {role}; run gen first")
    if role not in done:
        print(f"ALTER ROLE {role} WITH LOGIN PASSWORD '{m.group(2)}';")
        done.add(role)
print("GRANT USAGE ON SCHEMA public TO powersync_svc;")
# Only what the sync rules read; the rider tables hold device tokens and stay
# readable by rider_svc alone.
print("GRANT SELECT ON public.mrt_journey_matrix, public.mrt_schedule TO powersync_svc;")
# Azure's publication also lists tables the app no longer syncs; keep only what
# the sync rules read.
print("""DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
    ALTER PUBLICATION powersync SET TABLE public.mrt_journey_matrix, public.mrt_schedule;
  ELSE
    CREATE PUBLICATION powersync FOR TABLE public.mrt_journey_matrix, public.mrt_schedule;
  END IF;
END $$;""")
EOF
    "${psql[@]}" -d bus -At -c "SELECT rolname || ' password=' || (rolpassword IS NOT NULL) FROM pg_authid WHERE rolname IN ('bus_migrator','api_svc','realtime_svc','rider_svc','pipeline_svc','powersync_svc') ORDER BY 1"
}

rotate() {
    local env_file="$1" files_dir="$2" role="$3" deployments d
    [ -f "$env_file" ] || die "env file not found: $env_file"
    case "$role" in
        api_svc) deployments="api" ;;
        realtime_svc) deployments="realtime" ;;
        rider_svc) deployments="rider-api rider-worker" ;;
        powersync_svc) deployments="powersync" ;;
        pipeline_svc | bus_migrator) deployments="" ;; # Jobs read the Secret when they start
        *) die "unknown role: $role" ;;
    esac
    cp -p "$env_file" "$env_file.bak-$(date +%Y%m%d%H%M%S)"
    python3 - "$env_file" "$URLS" "$role" <<'PY' | "${psql[@]}" -d bus
import os, re, secrets, sys
path, spec, role = sys.argv[1], [s.split(":") for s in sys.argv[2].split()], sys.argv[3]
keys = {k for k, r, _ in spec if r == role}
pw = secrets.token_hex(24)
rx = re.compile(r"^(postgres://[^:/@]+:)([0-9a-f]+)(@.*)$")
out, seen = [], set()
for l in open(path).read().splitlines():
    k, _, v = l.partition("=")
    m = rx.match(v)
    if k in keys and m:
        l = f"{k}={m.group(1)}{pw}{m.group(3)}"
        seen.add(k)
    out.append(l)
if seen != keys:
    sys.exit(f"{sorted(keys - seen)} missing a cluster URL for {role}; run gen first")
open(path, "w").write("\n".join(out) + "\n")
os.chmod(path, 0o600)
print(f"ALTER ROLE {role} WITH PASSWORD '{pw}';")
PY
    # The sealing scripts live in the private bus-infra checkout and cd into it,
    # so relative paths from here would point inside bus-infra.
    "$INFRA_DIR/scripts/k3s-secrets.sh" seal \
        "$(cd "$(dirname "$env_file")" && pwd)/$(basename "$env_file")" "$(cd "$files_dir" && pwd)"
    "$INFRA_DIR/scripts/k3s-secrets.sh" apply
    for d in $deployments; do
        kubectl -n bus rollout restart "deploy/$d"
        kubectl -n bus rollout status "deploy/$d" --timeout=300s
    done
    echo "k3s-db-credentials: rotated $role"
}

case "${1:-}" in
    gen) [ "$#" -eq 2 ] || die "usage: $0 gen <env-file>"; gen "$2" ;;
    prepare) prepare ;;
    finish) [ "$#" -eq 2 ] || die "usage: $0 finish <env-file>"; finish "$2" ;;
    apply-superuser) [ "$#" -eq 2 ] || die "usage: $0 apply-superuser <migration>"; apply_superuser "$2" ;;
    rotate) [ "$#" -eq 4 ] || die "usage: $0 rotate <env-file> <secret-files-dir> <role>"; rotate "$2" "$3" "$4" ;;
    *) die "usage: $0 <gen <env-file>|prepare|finish <env-file>|apply-superuser <migration>|rotate <env-file> <secret-files-dir> <role>>" ;;
esac
