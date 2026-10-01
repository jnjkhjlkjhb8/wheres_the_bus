#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

DEFAULT_CAP=1000
budget_file="scripts/testdata/file-budgets.txt"

fail=0
warn=0
ok() { printf '  OK   %s\n' "$*"; }
bad() {
  printf '  FAIL %s\n' "$*"
  fail=1
}
warning() {
  printf '  WARN %s\n' "$*"
  warn=1
}

budget_for() { # <file> -> budget lines, or empty when unlisted
  grep -F "$1|" "$budget_file" 2>/dev/null | grep -v '^#' \
    | awk -F'|' -v f="$1" '$1 == f { print $2; exit }'
}

# list_sources <root> — tracked Go/Dart sources minus generated output.
list_sources() {
  if [ "$1" = "$repo_root" ]; then
    git ls-files '*.go' '*.dart'
  else
    (cd "$1" && find . -type f \( -name '*.go' -o -name '*.dart' \) | sed 's|^\./||')
  fi | grep -v -E '(^|/)app/lib/data/generated/|\.pb\.go$'
}

run_check() {
  local root="$1" f lines budget regressions=""
  while IFS= read -r f; do
    [ -f "$root/$f" ] || continue
    lines="$(wc -l <"$root/$f" | tr -d ' ')"
    budget="$(budget_for "$f")"
    if [ -n "$budget" ]; then
      if [ "$lines" -gt "$budget" ]; then
        regressions=1
        bad "$f grew to $lines lines, past its ratcheted budget of $budget (split it, or raise the budget in review)"
      elif [ "$lines" -le "$DEFAULT_CAP" ]; then
        warning "$f is now $lines lines (<= cap $DEFAULT_CAP); prune its stale budget entry"
      fi
    elif [ "$lines" -gt "$DEFAULT_CAP" ]; then
      regressions=1
      bad "$f is $lines lines, over the $DEFAULT_CAP-line cap for files without a ratcheted budget"
    fi
  done < <(list_sources "$root")
  [ -z "$regressions" ] && ok "no file exceeds its budget (cap ${DEFAULT_CAP}, $(grep -cv '^#' "$budget_file" 2>/dev/null || echo 0) ratcheted entries)"
}

self_test() {
  # Not `local`: the EXIT trap must still see the path under `set -u`.
  st_root="$(mktemp -d)"
  trap 'rm -rf "$st_root"' EXIT
  mkdir -p "$st_root/services/demo"
  seq 1 $((DEFAULT_CAP + 1)) | sed 's/^/\/\/ line /' >"$st_root/services/demo/violate_budget.go"

  echo "self-test: expecting one FAIL line against a synthetic tree"
  local st_out
  st_out="$(run_check "$st_root")"
  printf '%s\n' "$st_out" | sed 's/^/  | /'
  if [ "$(printf '%s\n' "$st_out" | grep -c 'FAIL')" -ne 1 ]; then
    echo "self-test FAILED: over-cap synthetic file was not flagged"
    exit 1
  fi
  echo "self-test: RED confirmed; now checking the real tree"
  fail=0 warn=0
}

case "${1:-}" in
  --self-test) self_test ;;
  "") ;;
  *)
    echo "usage: $0 [--self-test]" >&2
    exit 2
    ;;
esac

echo "== file-size budgets (Go + Dart) =="
run_check "$repo_root"

printf '\n'
if [ "$fail" -eq 0 ]; then
  echo "RESULT: GREEN — no file-size regressions."
else
  echo "RESULT: RED — see FAIL lines above."
fi
exit "$fail"
