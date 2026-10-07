#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0
note() { printf '%s\n' "$*"; }
ok() { printf '  OK   %s\n' "$*"; }
bad() {
  printf '  FAIL %s\n' "$*"
  fail=1
}

note "== Non-root USER in final image stage =="
check_dockerfile_user() {
  local name="$1" file="$2"
  if [ ! -f "$file" ]; then
    bad "$name: $file not found"
    return
  fi
  local last_user
  last_user=$(grep -E '^USER ' "$file" | tail -1 | awk '{print $2}' || true)
  if [ -z "$last_user" ]; then
    bad "$name: no USER directive in $file (runs as root)"
  elif [ "$last_user" = "root" ] || [ "$last_user" = "0" ] || [ "$last_user" = "0:0" ]; then
    bad "$name: USER directive resolves to root in $file"
  else
    ok "$name: USER $last_user in $file"
  fi
}
check_dockerfile_user "router" services/api/Dockerfile
check_dockerfile_user "functions" services/worker/Dockerfile

note ""
note "== .dockerignore present and excludes secrets/build output =="
if [ ! -f .dockerignore ]; then
  bad ".dockerignore missing at repo root"
elif grep -qE '^\*$' .dockerignore; then
  reincluded=""
  for pattern in '^!\.git' '^!env/' '^!secrets' '^!osrm-data' '^!app/build' '^!\.dart_tool'; do
    grep -qE "$pattern" .dockerignore && reincluded="$reincluded $pattern"
  done
  if [ -z "$reincluded" ]; then
    ok ".dockerignore is deny-by-default (allowlist style); no sensitive/build paths re-included"
  else
    bad ".dockerignore re-includes sensitive/build paths:$reincluded"
  fi
else
  missing=""
  for pattern in '.git' 'env/*.env' 'secrets/' 'osrm-data/' 'app/build' '.dart_tool'; do
    grep -qF "$pattern" .dockerignore || missing="$missing $pattern"
  done
  if [ -z "$missing" ]; then
    ok ".dockerignore covers git/env/secrets/osrm-data/build/dart_tool"
  else
    bad ".dockerignore missing patterns:$missing"
  fi
fi

note ""
note "== OSRM PBF fetch: atomic download + checksum =="
osrm_fetch_cmd=$(awk '/^  osrm-fetch:/{f=1} f{print} f && /restart:/{exit}' docker/docker-compose.yaml)
if echo "$osrm_fetch_cmd" | grep -q 'sha256sum\|md5sum'; then
  ok "osrm-fetch verifies a checksum before use"
else
  bad "osrm-fetch does not verify a checksum (sha256sum/md5sum) of the download"
fi
if echo "$osrm_fetch_cmd" | grep -qE '\.tmp|\.part' && echo "$osrm_fetch_cmd" | grep -q 'mv '; then
  ok "osrm-fetch downloads to a temp path and renames atomically"
else
  bad "osrm-fetch does not download-then-rename atomically (no .tmp path + mv)"
fi

note ""
note "== MOTIS import directory is content-addressed =="
motis_import_cmd=$(awk '/^  motis-import:/{f=1} f{print} f && /restart:/{exit}' docker/docker-compose.yaml)
if echo "$motis_import_cmd" | grep -q 'gtfs_sha=' && echo "$motis_import_cmd" | grep -q 'pbf_sha='; then
  ok "motis-import derives its data directory from both input checksums"
else
  bad "motis-import's data directory is not derived from the gtfs.zip + PBF checksums (stale-data risk)"
fi
if echo "$motis_import_cmd" | grep -q '\.build' && echo "$motis_import_cmd" | grep -qE 'mv .*\.build/data'; then
  ok "motis-import builds out of line and renames the finished set into place"
else
  bad "motis-import does not build into .build/ and rename (a running motis could read a half-built set)"
fi

note ""
note "== MOTIS healthcheck uses a real MOTIS HTTP endpoint =="
motis_healthcheck_test=$(awk '
  /^  motis:$/ { f=1; next }
  f && /^  [a-zA-Z0-9_-]+:$/ { exit }
  f && /^ *test:/ { print }
' docker/docker-compose.yaml | grep -v '^ *#')
if echo "$motis_healthcheck_test" | grep -q '/api/v1/health'; then
  ok "motis healthcheck asserts feed freshness via /api/v1/health"
elif echo "$motis_healthcheck_test" | grep -qE '/api/v1/geocode|/api/v1/reverse-geocode|/api/v6/'; then
  bad "motis healthcheck probes a routing endpoint; /api/v1/health also proves the feeds are being consumed"
else
  bad "motis healthcheck does not reference a documented MOTIS endpoint"
fi
if echo "$motis_healthcheck_test" | grep -q 'curl'; then
  bad "motis healthcheck invokes curl, which the Alpine-based MOTIS image does not ship"
elif echo "$motis_healthcheck_test" | grep -q 'wget'; then
  ok "motis healthcheck probes via busybox wget (present in the Alpine-based image)"
else
  bad "motis healthcheck does not use wget -- verify its probe binary exists in the pinned image"
fi

note ""
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  note "== Compose-config checks SKIPPED (docker/compose not available) =="
else
  note "== Compose-config checks (docker compose config, test env) =="
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  cfg="$work_dir/config.yaml"
  # ENV_FILE (not BUS_ENV_FILE) is what docker-compose.yaml actually reads
  # (`env_file: ${ENV_FILE:-./.env}`), so it must be exported here rather
  # than left to the --env-file default.
  if ! ENV_FILE=env/test.env.example docker compose \
    --project-directory . \
    -p bus-hardening-check \
    --env-file env/test.env.example \
    -f docker/docker-compose.yaml \
    -f docker/docker-compose.prod.yaml \
    --profile gpu \
    --profile motis \
    config >"$cfg" 2>"$work_dir/config.err"; then
    cat "$work_dir/config.err" >&2
    exit 1
  fi

  services="router functions ingestor loader redis powersync cloudflared motis motis-import osrm-fetch"
  long_running="router functions ingestor loader redis powersync cloudflared motis"

  service_block() {
    # service_block <name> <file> — prints the YAML block for one service.
    awk -v svc="  $1:" '
      $0 == svc { f=1; print; next }
      f && /^  [a-zA-Z0-9_-]+:$/ { exit }
      f { print }
    ' "$2"
  }

  # Top-level service keys sit at 4-space indent in `docker compose config`
  # output; nested list-item fields (e.g. a bind mount's own `read_only:
  # true`) sit deeper. Anchoring on 4-space indent avoids matching those.
  note "-- no-new-privileges --"
  for s in $long_running; do
    blk=$(service_block "$s" "$cfg")
    if echo "$blk" | grep -A3 '^    security_opt:' | grep -qE '^ *- no-new-privileges:true$'; then
      ok "$s: no-new-privileges set"
    else
      bad "$s: security_opt no-new-privileges:true missing"
    fi
  done

  note "-- cap_drop ALL --"
  for s in $long_running; do
    blk=$(service_block "$s" "$cfg")
    if echo "$blk" | grep -A3 '^    cap_drop:' | grep -q '^ *- ALL$'; then
      ok "$s: cap_drop ALL set"
    else
      bad "$s: cap_drop: [ALL] missing"
    fi
  done

  note "-- read_only root filesystem --"
  for s in $long_running; do
    blk=$(service_block "$s" "$cfg")
    if echo "$blk" | grep -qE '^    read_only: true$'; then
      ok "$s: read_only root fs"
    else
      bad "$s: read_only: true missing"
    fi
  done

  note "-- pids_limit and cpus set --"
  for s in $long_running; do
    blk=$(service_block "$s" "$cfg")
    has_pids=$(echo "$blk" | grep -cE '^    pids_limit: ' || true)
    has_cpus=$(echo "$blk" | grep -cE '^    cpus: ' || true)
    if [ "$has_pids" -gt 0 ] && [ "$has_cpus" -gt 0 ]; then
      ok "$s: pids_limit + cpus set"
    else
      bad "$s: pids_limit and/or cpus missing"
    fi
  done

  note "-- pinned images (digest, not :latest) --"
  for s in $services; do
    blk=$(service_block "$s" "$cfg")
    if echo "$blk" | grep -q '^    build:'; then
      ok "$s: locally built (build: present) -- base image pin checked via Dockerfile"
      continue
    fi
    image_line=$(echo "$blk" | grep -m1 '^    image:' || true)
    [ -z "$image_line" ] && continue
    if echo "$image_line" | grep -q ':latest'; then
      bad "$s: image pinned to :latest -- $image_line"
    elif echo "$image_line" | grep -q '@sha256:'; then
      ok "$s: image pinned by digest -- $image_line"
    else
      bad "$s: image not pinned by digest -- $image_line"
    fi
  done

  note "-- Dockerfile FROM base images pinned by digest --"
  for pair in "router:services/api/Dockerfile" "functions:services/worker/Dockerfile"; do
    name="${pair%%:*}"
    file="${pair#*:}"
    unpinned=$(grep -E '^FROM ' "$file" | grep -v '@sha256:' || true)
    if [ -z "$unpinned" ]; then
      ok "$name: all FROM lines pinned by digest"
    else
      bad "$name: unpinned FROM line(s) in $file: $unpinned"
    fi
  done

  note "-- no whole-secrets-directory mounts --"
  if grep -q '/run/secrets$' "$cfg" || grep -B1 'target: /run/secrets$' "$cfg" | grep -q 'source:'; then
    bad "a service still bind-mounts the whole secrets directory"
  else
    ok "no service mounts the whole ./secrets directory"
  fi
fi

note ""
if [ "$fail" -eq 0 ]; then
  note "RESULT: GREEN — all container hardening checks passed."
else
  note "RESULT: RED — see FAIL lines above."
fi
exit "$fail"
