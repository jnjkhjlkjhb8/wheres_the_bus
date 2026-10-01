#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

allowlist_dir="scripts/env-allowlists"
services=(router functions ingestor loader powersync motis)
envs=(test staging prod)

fail=0
note() { printf '%s\n' "$*"; }
ok() { printf '  OK   %s\n' "$*"; }
bad() {
  printf '  FAIL %s\n' "$*"
  fail=1
}

allowlist_keys() {
  # scripts/env-allowlists/<service>.txt -> sorted, deduped var names,
  # skipping blank lines and #-comments.
  grep -vE '^\s*(#|$)' "$allowlist_dir/${1}.txt" | sort -u
}

rendered_keys() {
  # <rendered-file> -> sorted, deduped KEY names from KEY=value lines.
  [ -f "$1" ] || return 0
  cut -d= -f1 "$1" | sort -u
}

check_env() {
  local env_name="$1" source_file="env/${env_name}.env.example"
  local work_dir
  work_dir="$(mktemp -d)"
  ./scripts/render-env.sh "$source_file" "$work_dir" >/dev/null
  for service in "${services[@]}"; do
    local rendered="$work_dir/${service}.env"
    local extra
    extra=$(comm -23 <(rendered_keys "$rendered") <(allowlist_keys "$service") || true)
    if [ -n "$extra" ]; then
      bad "$env_name/$service: rendered env has keys outside its allowlist: $(echo "$extra" | tr '\n' ' ')"
    else
      ok "$env_name/$service: rendered env ⊆ allowlist ($(rendered_keys "$rendered" | wc -l | tr -d ' ') keys)"
    fi
  done
  rm -rf "$work_dir"
}

note "== Per-service env allowlist (render + subset check, all example envs) =="
for env_name in "${envs[@]}"; do
  check_env "$env_name"
done

note "== Staging isolation contract =="
staging_source="env/staging.env.example"
if grep -q '^PG_SCHEMA=staging$' "$staging_source" && grep -q '^TDX_CLIENT_ID=$' "$staging_source" && grep -q '^TDX_CLIENT_SECRET=$' "$staging_source"; then
  ok "staging uses schema=staging and has no TDX writer credentials"
else
  bad "staging must use schema=staging and empty TDX writer credentials"
fi
if grep -q '^PS_SOURCE_DATABASE_URL=.*search_path%3Dstaging' "$staging_source"; then
  ok "staging PowerSync source is schema-scoped"
else
  bad "staging PowerSync source must explicitly target the staging schema"
fi
if grep -q '^tunnel: REPLACE_WITH_' cloudflared/config.staging.yml; then
  ok "staging tunnel fails closed until operator supplies its identity"
else
  bad "staging tunnel config must fail closed when its operator identity is absent"
fi

if [ "$fail" -ne 0 ]; then
  note ""
  note "RESULT: RED — see FAIL lines above."
  exit 1
fi

note ""
note "RESULT: GREEN — every service's rendered env is a subset of its allowlist."
