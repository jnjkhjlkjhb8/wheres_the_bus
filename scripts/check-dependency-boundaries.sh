#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dart_pkg="wheres_the_bus"
go_module="github.com/jnjkhjlkjhb8/wheres_the_bus"
feature_allowlist="scripts/testdata/dependency-boundary-allowlist.txt"
proto_allowlist="scripts/testdata/proto-confinement-allowlist.txt"

fail=0
note() { printf '\n== %s ==\n' "$*"; }
ok() { printf '  OK   %s\n' "$*"; }
bad() {
  printf '  FAIL %s\n' "$*"
  fail=1
}

# allow <allowlist-file> <key> — true when key is an exact allowlist line.
allow() {
  [ -f "$1" ] && grep -Fxq "$2" "$1"
}

# scan_feature_isolation <lib-root> <features-prefix-inside-lib-root>
# Emits "<file>|<imported-feature>" for every cross-feature import found.
scan_feature_isolation() {
  local lib_root="$1" prefix="$2" f rest feat line imported
  list_dart_files "$lib_root" "$prefix" | while read -r f; do
    rest="${f#"$prefix"/}"
    feat="${rest%%/*}"
    grep -n "import 'package:$dart_pkg/features/" "$lib_root/$f" 2>/dev/null \
      | while IFS= read -r line; do
        imported="$(printf '%s' "$line" | sed -E "s|.*features/([^/']+)/.*|\1|")"
        if [ "$imported" != "$feat" ]; then
          printf '%s|%s\n' "$f" "$imported"
        fi
      done
  done
}

# scan_proto_confinement <lib-root>
# Emits "<file>" for every Dart file outside app/lib/data that imports the
# generated protobuf output.
scan_proto_confinement() {
  local lib_root="$1" f
  list_dart_files "$lib_root" "app/lib" | while read -r f; do
    case "$f" in app/lib/data/*) continue ;; esac
    if grep -q "data/generated/" "$lib_root/$f" 2>/dev/null; then
      printf '%s\n' "$f"
    fi
  done
}

# scan_go_layering <root>
# Emits "<file>|<forbidden-import>" for router<->functions imports.
scan_go_layering() {
  local root="$1" f
  list_go_files "$root" "services/api" | while read -r f; do
    grep -n "\"$go_module/services/worker" "$root/$f" 2>/dev/null \
      | while IFS= read -r _; do printf '%s|services/worker\n' "$f"; done
  done
  list_go_files "$root" "services/worker" | while read -r f; do
    grep -n "\"$go_module/services/api" "$root/$f" 2>/dev/null \
      | while IFS= read -r _; do printf '%s|services/api\n' "$f"; done
  done
}

# File enumeration: tracked files in repo mode, find(1) under a synthetic
# self-test root (which has no git metadata).
scan_root="$repo_root"
list_dart_files() { # <root> <path-prefix>
  if [ "$1" = "$repo_root" ]; then
    git ls-files "$2/**/*.dart" "$2/*.dart"
  else
    (cd "$1" && find "$2" -name '*.dart' -type f 2>/dev/null | sed 's|^\./||')
  fi
}
list_go_files() { # <root> <path-prefix>
  if [ "$1" = "$repo_root" ]; then
    git ls-files "$2/**/*.go" "$2/*.go"
  else
    (cd "$1" && find "$2" -name '*.go' -type f 2>/dev/null | sed 's|^\./||')
  fi
}

run_checks() {
  local root="$1"

  note "(a) Flutter feature isolation"
  local pair new_pairs=""
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    if allow "$feature_allowlist" "$pair"; then
      : # ratcheted pre-existing coupling
    else
      new_pairs=1
      bad "new cross-feature import: ${pair%%|*} imports features/${pair##*|} (add a shared seam instead)"
    fi
  done < <(scan_feature_isolation "$root" "app/lib/features" | sort -u)
  [ -z "$new_pairs" ] && ok "no cross-feature imports beyond the ratcheted allowlist"

  note "(b) generated protobuf confinement"
  local offender new_offenders=""
  while IFS= read -r offender; do
    [ -z "$offender" ] && continue
    if allow "$proto_allowlist" "$offender"; then
      :
    else
      new_offenders=1
      bad "new data/generated/ import outside app/lib/data: $offender (wrap the type in a data-layer model)"
    fi
  done < <(scan_proto_confinement "$root" | sort -u)
  [ -z "$new_offenders" ] && ok "generated protobuf types confined to app/lib/data (plus ratcheted allowlist)"

  note "(c) Go service layering"
  local crossing found=""
  while IFS= read -r crossing; do
    [ -z "$crossing" ] && continue
    found=1
    bad "layering breach: ${crossing%%|*} imports ${crossing##*|} (move shared code to services/shared)"
  done < <(scan_go_layering "$root" | sort -u)
  [ -z "$found" ] && ok "services/api and services/worker do not import each other"
}

self_test() {
  # Intentionally not `local`: the EXIT trap fires after this function
  # returns and must still see the path under `set -u`.
  st_root="$(mktemp -d)"
  trap 'rm -rf "$st_root"' EXIT

  # Synthetic violations, one per boundary. Never touches the repository.
  mkdir -p "$st_root/app/lib/features/bus" "$st_root/app/lib/features/rail" \
    "$st_root/app/lib/shared" "$st_root/services/api" "$st_root/services/worker"
  printf "import 'package:%s/features/rail/rail_bloc.dart';\n" "$dart_pkg" \
    >"$st_root/app/lib/features/bus/violate_feature.dart"
  printf "import 'package:%s/data/generated/bus.pb.dart';\n" "$dart_pkg" \
    >"$st_root/app/lib/shared/violate_proto.dart"
  printf 'package router\n\nimport "%s/services/worker"\n' "$go_module" \
    >"$st_root/services/api/violate_layering.go"

  echo "self-test: expecting three FAIL lines against a synthetic tree"
  local st_out
  st_out="$(run_checks "$st_root")"
  printf '%s\n' "$st_out" | sed 's/^/  | /'
  local st_fails
  st_fails="$(printf '%s\n' "$st_out" | grep -c 'FAIL')"
  if [ "$st_fails" -ne 3 ]; then
    echo "self-test FAILED: expected 3 synthetic violations, scanner reported $st_fails"
    exit 1
  fi
  echo "self-test: RED confirmed (3/3 synthetic violations caught); now checking the real tree"
  fail=0
}

case "${1:-}" in
  --self-test) self_test ;;
  "") ;;
  *)
    echo "usage: $0 [--self-test]" >&2
    exit 2
    ;;
esac

run_checks "$repo_root"

# (d) Allowlist staleness — repo mode only; the synthetic self-test tree shares
# none of the real pairs, so running this against it would flag every line.
note "(d) allowlist staleness"
observed="$(scan_feature_isolation "$repo_root" "app/lib/features" | sort -u)"
stale=""
while IFS= read -r entry; do
  case "$entry" in '#'* | '') continue ;; esac
  if ! printf '%s\n' "$observed" | grep -Fxq "$entry"; then
    stale=1
    bad "stale allowlist entry: ${entry%%|*} no longer imports features/${entry##*|} (delete the line so the ratchet tightens)"
  fi
done <"$feature_allowlist"
[ -z "$stale" ] && ok "every allowlisted pair still exists in the tree"

printf '\n'
if [ "$fail" -eq 0 ]; then
  echo "RESULT: GREEN — all dependency boundaries hold."
else
  echo "RESULT: RED — see FAIL lines above."
fi
exit "$fail"
