#!/usr/bin/env bash
set -euo pipefail

env_name="${1:?usage: deploy-transaction.sh <staging|prod> <router-image-ref> <functions-image-ref>}"
router_image="${2:?usage: deploy-transaction.sh <staging|prod> <router-image-ref> <functions-image-ref>}"
functions_image="${3:?usage: deploy-transaction.sh <staging|prod> <router-image-ref> <functions-image-ref>}"

case "$env_name" in
  staging)
    project=staging
    env_file=env/staging.env
    overlay=docker/docker-compose.staging.yaml
    ;;
  prod)
    project=prod
    env_file=env/prod.env
    overlay=docker/docker-compose.prod.yaml
    ;;
  *)
    echo "deploy-transaction: unknown environment '$env_name' (want staging or prod)" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

state_dir="/var/lib/bus"
state_file="$state_dir/last-known-good-${env_name}.json"
release_dir="$state_dir/releases/$env_name"

log() { printf '[deploy-transaction] %s\n' "$*"; }

check_secret_file() {
  local file="$1" mode owner
  [ -f "$file" ] || { log "FATAL: required secret file is missing: $file"; return 1; }
  mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
  owner=$(stat -c '%u' "$file" 2>/dev/null || stat -f '%u' "$file")
  [ "$mode" = 600 ] || { log "FATAL: secret file $file must be mode 0600 (found $mode)"; return 1; }
  [ "$owner" = "$(id -u)" ] || { log "FATAL: secret file $file is not owned by the deploy user"; return 1; }
}

rendered_dir="env/.rendered/${env_name}"
if ! ./scripts/render-env.sh "$env_file" "$rendered_dir"; then
  log "FATAL: scripts/render-env.sh failed for $env_file -- refusing to deploy with un-scoped env files"
  exit 1
fi
for svc in router functions ingestor loader powersync; do
  if [ ! -s "$rendered_dir/${svc}.env" ]; then
    log "FATAL: rendered env file $rendered_dir/${svc}.env is missing or empty -- refusing to deploy with un-scoped env files"
    exit 1
  fi
done
log "rendered per-service env files into $rendered_dir"
for rendered in "$rendered_dir"/*.env; do
  check_secret_file "$rendered"
done

verify_migration_ledger() {
  local db_url pg_schema
  db_url=$(grep -m1 '^DATABASE_URL=' "$env_file" | cut -d= -f2-)
  pg_schema=$(grep -m1 '^PG_SCHEMA=' "$env_file" | cut -d= -f2-)
  if [ -z "$db_url" ] || [ -z "$pg_schema" ]; then
    log "FATAL: DATABASE_URL or PG_SCHEMA missing from $env_file -- cannot verify the migration ledger"
    return 1
  fi

  # Same pinned image ci.yaml uses for its postgres service; the deploy host
  # has no psql of its own.
  local ledger
  if ! ledger=$(docker run --rm \
      -e PGOPTIONS="-c search_path=${pg_schema}" \
      postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777 \
      psql "$db_url" -X -v ON_ERROR_STOP=1 -At -F ' ' \
      -c 'SELECT filename, sha256 FROM schema_migrations'); then
    log "FATAL: could not read ${pg_schema}.schema_migrations -- refusing to deploy without a readable migration ledger (if this environment predates the ledger, apply migrations/2026-07-17-schema-migrations-ledger.sql first)"
    return 1
  fi

  local failed=0 f name want have
  for f in migrations/*.sql; do
    name=$(basename "$f")
    want=$(sha256sum "$f" | awk '{print $1}')
    have=$(printf '%s\n' "$ledger" | awk -v n="$name" '$1 == n {print $2}')
    if [ -z "$have" ]; then
      if head -n1 "$f" | grep -q '^-- REPLAY: skip'; then
        continue
      fi
      log "FATAL: $name is not recorded in ${pg_schema}.schema_migrations -- apply it (scripts/apply-migration.sh), or backfill the ledger if it was applied before the ledger existed (migrations/README.md, \"Ledger\")"
      failed=1
    elif [ "$have" != "$want" ]; then
      log "FATAL: $name checksum differs from the recorded apply in ${pg_schema}.schema_migrations -- the file was edited after being applied; supersede it with a new dated file (migrations/README.md, \"Naming\")"
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  log "migration ledger OK: every dated migration is recorded in ${pg_schema}.schema_migrations with a matching checksum"
}

if ! verify_migration_ledger; then
  log "deploy REFUSED: migration ledger verification failed -- nothing was pulled or restarted"
  exit 1
fi

compose() {
  local image_router="$1" image_functions="$2"
  shift 2
  ENV_FILE="$env_file" \
    ENV_FILE_ROUTER="$rendered_dir/router.env" \
    ENV_FILE_FUNCTIONS="$rendered_dir/functions.env" \
    ENV_FILE_INGESTOR="$rendered_dir/ingestor.env" \
    ENV_FILE_LOADER="$rendered_dir/loader.env" \
    ENV_FILE_POWERSYNC="$rendered_dir/powersync.env" \
    ROUTER_IMAGE="$image_router" FUNCTIONS_IMAGE="$image_functions" \
    docker compose --project-directory . -p "$project" --env-file "$env_file" \
    -f docker/docker-compose.yaml -f "$overlay" "$@"
}

running_image() {
  local service="$1" cid
  cid=$(compose "$router_image" "$functions_image" ps -q "$service" 2>/dev/null || true)
  [ -z "$cid" ] && return 0
  docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true
}

prev_router=$(running_image router)
prev_functions=$(running_image functions)
if [ -n "$prev_router" ] && [ -n "$prev_functions" ]; then
  log "captured currently running images for rollback: router=$prev_router functions=$prev_functions"
else
  log "no currently running router/functions image found (first deploy?) -- rollback unavailable this run"
fi

snapshot_release() {
  local destination="$1" manifest="$destination/release.json"
  mkdir -p "$destination"
  chmod 700 "$destination"
  cp docker/docker-compose.yaml "$destination/docker-compose.yaml"
  cp "$overlay" "$destination/overlay.yaml"
  cp -R "$rendered_dir" "$destination/env"
  chmod -R go-rwx "$destination/env"
  # Keep the fully resolved graph, including bind mounts and every service
  # image, beside the source inputs. It is the reviewable rollback contract;
  # it is never printed because env_file values can contain credentials.
  compose "$router_image" "$functions_image" config >"$destination/compose-resolved.yaml"
  # Resolve non-secret repository mounts to immutable copies in this release.
  # Secret mounts deliberately remain operator-owned paths and are never copied.
  mkdir -p "$destination/powersync" "$destination/motis" "$destination/cloudflared"
  cp powersync/config.yaml powersync/sync-rules.yaml "$destination/powersync/"
  cp motis/config.yml "$destination/motis/"
  cp cloudflared/config."$env_name".yml "$destination/cloudflared/config.yml"
  sed -i.bak \
    -e "s|$repo_root/powersync/|$destination/powersync/|g" \
    -e "s|$repo_root/motis/|$destination/motis/|g" \
    -e "s|$repo_root/cloudflared/config.$env_name.yml|$destination/cloudflared/config.yml|g" \
    "$destination/compose-resolved.yaml"
  rm -f "$destination/compose-resolved.yaml.bak"
  chmod 600 "$destination/compose-resolved.yaml"
  local images
  images=$(compose "$router_image" "$functions_image" config --images)
  {
    printf '{\n  "environment": "%s",\n  "commit": "%s",\n  "router": "%s",\n  "functions": "%s",\n  "images": [' "$env_name" "$(git rev-parse HEAD)" "$router_image" "$functions_image"
    printf '%s' "$images" | awk 'BEGIN { first=1 } NF { gsub(/"/, "\\\""); if (!first) printf ","; printf "\"%s\"", $0; first=0 }'
    printf ']\n}\n'
  } >"$manifest"
  chmod 600 "$manifest"
}

previous_release=""
if [ -f "$state_file" ]; then
  previous_release=$(sed -n 's/.*"release": "\([^"]*\)".*/\1/p' "$state_file" | head -1)
fi

mkdir -p "$release_dir"
current_release="$release_dir/$(date -u +%Y%m%dT%H%M%SZ)-$$"
snapshot_release "$current_release"

router_endpoint() {
  compose "$router_image" "$functions_image" port router 8080 2>/dev/null || true
}

smoke_test() {
  local endpoint
  endpoint=$(router_endpoint)
  if [ -z "$endpoint" ]; then
    log "smoke test FAILED: could not resolve router's published HTTP port"
    return 1
  fi
  if ! curl -sf --max-time 5 "http://${endpoint}/api/.well-known/jwks.json" >/dev/null; then
    log "smoke test FAILED: GET http://${endpoint}/api/.well-known/jwks.json did not return 200"
    return 1
  fi
  local not_healthy
  not_healthy=$(compose "$router_image" "$functions_image" ps --format json \
    | grep -o '"Health":"[a-z]*"' | grep -v '"Health":"healthy"' || true)
  if [ -n "$not_healthy" ]; then
    log "smoke test FAILED: not every service reports healthy: $not_healthy"
    return 1
  fi
  log "smoke test OK: router jwks endpoint 200, all services healthy"
}

deploy_digests() {
  local router_ref="$1" functions_ref="$2"
  compose "$router_ref" "$functions_ref" pull router functions ingestor loader
  compose "$router_ref" "$functions_ref" up -d --wait --no-build
}

rollback_release() {
  local release="$1"
  [ -n "$release" ] && [ -s "$release/compose-resolved.yaml" ] || {
    log "rollback REFUSED: last-known-good release snapshot is missing or incomplete"
    return 1
  }
  chmod 600 "$release/compose-resolved.yaml"
  docker compose --project-directory "$release" -p "$project" \
    -f "$release/compose-resolved.yaml" pull
  docker compose --project-directory "$release" -p "$project" \
    -f "$release/compose-resolved.yaml" up -d --wait --no-build
}

record_last_known_good() {
  mkdir -p "$state_dir"
  cat > "$state_file" <<EOF
{
  "environment": "$env_name",
  "router": "$router_image",
  "functions": "$functions_image",
  "release": "$current_release",
  "images_manifest": "$current_release/release.json",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  log "recorded new last-known-good: $state_file"
}

log "deploying to $env_name: router=$router_image functions=$functions_image"
if deploy_digests "$router_image" "$functions_image" && smoke_test; then
  record_last_known_good
  log "deploy SUCCEEDED"
  exit 0
fi

log "deploy FAILED"
if [ -n "$previous_release" ]; then
  log "rolling back to the complete last-known-good release snapshot"
  if rollback_release "$previous_release"; then
    log "rollback SUCCEEDED -- $env_name is back on the previous complete release"
  else
    log "rollback FAILED -- snapshot could not be re-enabled; manual intervention required"
  fi
else
  log "no previous release snapshot -- refusing image-only rollback; manual intervention required"
fi
exit 1
