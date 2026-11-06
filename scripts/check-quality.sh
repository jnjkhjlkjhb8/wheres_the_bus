#!/usr/bin/env bash
# CRAP, duplication and mutation gates for code changed since QUALITY_BASE.
# Coverage comes from `make quality` (or CI's test steps).
#
# usage: QUALITY_BASE=<rev> scripts/check-quality.sh <go|flutter> [...]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

base="${QUALITY_BASE:-HEAD}"
# GitHub sends an all-zero "before" sha on a branch's first push.
if [[ "$base" =~ ^0+$ ]]; then
  base=HEAD^
fi
crap_max=4
mutation_min=90
# Pinned like the other tools. crap4dart >= 0.10 needs Dart 3.13; bump it with
# the Flutter toolchain.
crap4dart_version=0.9.5
mutation_test_version=1.8.1
# Changed Go code goes through Uncle Bob's crapper/dryer/mutator. None of the
# three reads Dart. They have no tags, so they are pinned to commits.
ub_tools_pins="crapper@6fd92c4 dryer@66ff6d2 mutator@a5a0cb8"
ub_bin=""
dry_max=0.8
tools_bin="$repo_root/.tools/bin"
# Every tool below diffs through git, crap4dart with its own fixed arguments.
# Copy detection keeps moved or copy-then-trimmed code from counting as new;
# relative paths let crap4dart, which runs inside app/, match git's output to
# its files.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=diff.renames GIT_CONFIG_VALUE_0=copies
export GIT_CONFIG_KEY_1=diff.relative GIT_CONFIG_VALUE_1=true
export PATH="$tools_bin:$PATH:$HOME/.pub-cache/bin"

tmp="$(mktemp -d)"
cleanup() {
  git worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
  rm -rf "${tmp:?}"
}
trap cleanup EXIT

report_root="${QUALITY_REPORT_DIR:-$tools_bin/../quality/changed}"
mkdir -p "$report_root"
report_root="$(cd "$report_root" && pwd)"
if [[ "$report_root" == "$repo_root/"* ]] && ! git check-ignore -q "$report_root/manifest.json"; then
  echo "check-quality: QUALITY_REPORT_DIR inside the repository must be gitignored" >&2
  exit 2
fi
report_tool="$repo_root/scripts/quality-report.py"
changed_tool="$repo_root/scripts/quality-changed.py"

# Mutation tools rewrite sources in place, so they run on a throwaway worktree: HEAD plus this tree's
# uncommitted changes and gitignored generated code. The local checkout holds
# multi-GB build output that must not be copied.
make_worktree() {
  [ -d "$tmp/wt" ] && return
  git worktree add -q --detach "$tmp/wt" HEAD
  # --no-renames: a renamed file must show up as a delete plus an add here, or
  # its old path survives in the worktree and the move reads as a copy.
  {
    git diff --no-renames --name-only --diff-filter=d HEAD
    git ls-files --others --exclude-standard
    git ls-files --others --ignored --exclude-standard -- \
      'models/*.pb.go' 'app/lib/data/generated/*' 'app/lib/generated/*' 'app/lib/l10n/app_i18n*.dart'
  } | sort -u | while IFS= read -r f; do
    [ -f "$f" ] || continue
    # Mobile distribution archives are build outputs, never test inputs.
    case "$f" in *.ipa|*.apk|*.aab) continue ;; esac
    mkdir -p "$tmp/wt/$(dirname "$f")"
    cp "$f" "$tmp/wt/$f"
  done
  git diff --no-renames --name-only --diff-filter=D HEAD | while IFS= read -r f; do rm -f "${tmp:?}/wt/${f:?}"; done
  # Intent-to-add so new files show up in the worktree's own git diff.
  while IFS= read -r -d '' f; do git -C "$tmp/wt" add -N -- "$f"; done < <(git -C "$tmp/wt" ls-files -z --others --exclude-standard)
}

run_go() {
  local cover="${QUALITY_GO_COVER:-coverage.out}"
  if [ ! -f "$cover" ]; then
    echo "check-quality: $cover missing; run go test -coverprofile=$cover ./... first" >&2
    exit 1
  fi
  local reports
  reports="$(mktemp -d "$report_root/go-changed.XXXXXX")"
  python3 "$changed_tool" inventory "$repo_root" "$base" "$reports"
  local files=() file
  while IFS= read -r file; do files+=("$file"); done <"$reports/go-files.txt"
  if [ "${#files[@]}" -eq 0 ]; then
    echo "no changed go files"
    return
  fi
  install_ub_tools
  # The tools write .metrics/ and target/ into the project root they run in,
  # and their --changed reads git status, which is empty in CI: run them in the
  # worktree on the inventory's explicit file list.
  make_worktree
  mkdir -p "$tmp/wt/target/coverage/go"
  python3 "$report_tool" normalize-go-coverage "$cover" "$reports/coverage.normalized.out" "$reports/coverage-normalization.json"
  # mutator cannot map import paths to files (crapper can); repo-relative paths work for both.
  sed "s#^$(go list -m)/##" "$reports/coverage.normalized.out" >"$tmp/wt/target/coverage/go/coverage.out"

  echo "== quality: go CRAP <= $crap_max in files changed since $base =="
  # --threshold compares the unrounded score; a function it could not score
  # (no coverage data at all) is nil and would slip past it.
  (cd "$tmp/wt" && "$ub_bin/crapper" --use-existing-coverage --threshold "$crap_max" "${files[@]}") | tee "$reports/crap.log"
  if grep -q ':crap nil' "$tmp/wt/.metrics/crap.edn"; then
    echo "go CRAP: functions without coverage data ($tmp/wt/.metrics/crap.edn)" >&2
    return 1
  fi

  echo "== quality: go duplication < $dry_max on lines changed since $base =="
  (cd "$tmp/wt" && "$ub_bin/dryer" --edn --threshold "$dry_max") >"$reports/dry.edn"
  python3 "$changed_tool" go-dry "$reports/manifest.json" "$reports/dry.edn"

  echo "== quality: go mutation efficacy and coverage >= $mutation_min% on lines changed since $base =="
  python3 "$changed_tool" go-tests "$tmp/wt" "$reports/manifest.json" "$reports/go-tests.json"
  local logs=() log tool_status
  for file in "${files[@]}"; do
    log="$reports/mutation/$file.log"
    mkdir -p "$(dirname "$log")"
    tool_status=0
    # Exit 3 means at least one survivor, stricter than the threshold, so the
    # score is computed from the site log instead. Exit 2 is a failing baseline.
    # The default timeout is 10x the baseline, and the baseline already includes
    # a cold compile: a mutant that turns a loop infinite waited ~110 s per site.
    (cd "$tmp/wt" && "$ub_bin/mutator" --use-existing-coverage --max-workers 1 --timeout-factor 3 \
      --lines "$(python3 "$changed_tool" go-lines "$reports/manifest.json" "$file")" \
      --test-command "$(python3 "$changed_tool" go-test-command "$reports/go-tests.json" "$file")" \
      "$file") >"$log" 2>&1 || tool_status=$?
    cat "$log"
    case "$tool_status" in
      0|3) logs+=("$log") ;;
      *) echo "$file: mutator failed (exit $tool_status, $log)" >&2; return 1 ;;
    esac
  done
  python3 "$changed_tool" go-mutation "$reports/manifest.json" "${logs[@]}"
}

# crapper, dryer and mutator: Python tools fetched at pinned commits into one
# virtualenv. mutator imports crapper, which the shared venv provides.
install_ub_tools() {
  local dir="$tools_bin/../ub" pin name commit
  if [ "$(cat "$dir/.installed" 2>/dev/null)" != "$ub_tools_pins" ]; then
    rm -rf "$dir"
    mkdir -p "$dir"
    for pin in $ub_tools_pins; do
      name="${pin%%@*}" commit="${pin#*@}"
      git clone -q "https://github.com/unclebob/$name" "$dir/$name"
      git -C "$dir/$name" checkout -q "$commit"
    done
    python3 -m venv "$dir/.venv"
    "$dir/.venv/bin/pip" install -q "$dir/crapper" "$dir/dryer" "$dir/mutator"
    printf '%s' "$ub_tools_pins" >"$dir/.installed"
  fi
  ub_bin="$(cd "$dir/.venv/bin" && pwd)"
}

run_flutter() {
  local lcov="${QUALITY_LCOV:-app/coverage/lcov.info}"
  if [ ! -f "$lcov" ]; then
    echo "check-quality: $lcov missing; run (cd app && flutter test --coverage) first" >&2
    exit 1
  fi
  lcov="$(cd "$(dirname "$lcov")" && pwd)/$(basename "$lcov")"
  local reports dart_crap_tool tool_status file rel log xml failed=0
  reports="$(mktemp -d "$report_root/flutter-changed.XXXXXX")"
  python3 "$changed_tool" inventory "$repo_root" "$base" "$reports"
  if [ ! -s "$reports/flutter-files.txt" ]; then
    echo "no changed Dart source lines"
    return
  fi
  dart pub global activate crap4dart "$crap4dart_version" >"$reports/crap-tool.log" 2>&1
  dart_crap_tool="$(python3 "$repo_root/scripts/quality-crap4dart.py")"
  cp "$repo_root/.tools/quality-runtime/crap4dart-$crap4dart_version-annotation-start/provenance.json" "$reports/crap-tool-provenance.json"
  python3 "$report_tool" dart-tests "$repo_root" "$reports/manifest.json" "$reports/test-selection.json"
  echo "== quality: Dart CRAP <= $crap_max on authored methods changed since $base =="
  if [ -s "$reports/flutter-tracked.txt" ]; then
    tool_status=0
    (cd app && "$dart_crap_tool" analyze --diff-base "$base" --format json --threshold "$crap_max" --lcov "$lcov" </dev/null) \
      >"$reports/crap-tracked.raw.json" 2>"$reports/crap-tracked.log" || tool_status=$?
    python3 "$changed_tool" dart-report "$reports/manifest.json" "$reports/crap-tracked.raw.json" "$reports/crap-tracked.json" "$tool_status"
  fi
  local untracked=()
  while IFS= read -r file; do [ -z "$file" ] || untracked+=("$file"); done <"$reports/flutter-untracked.txt"
  if [ "${#untracked[@]}" -gt 0 ]; then
    tool_status=0
    (cd app && "$dart_crap_tool" analyze "${untracked[@]}" --format json --threshold "$crap_max" --lcov "$lcov" </dev/null) \
      >"$reports/crap-untracked.raw.json" 2>"$reports/crap-untracked.log" || tool_status=$?
    python3 "$changed_tool" dart-report "$reports/manifest.json" "$reports/crap-untracked.raw.json" "$reports/crap-untracked.json" "$tool_status"
  fi
  echo "== quality: Dart mutation score >= $mutation_min% on authored lines changed since $base =="
  dart pub global activate mutation_test "$mutation_test_version" >"$reports/mutation-tool.log" 2>&1
  make_worktree
  (cd "$tmp/wt/app" && flutter pub get) >"$reports/pub-get.log" 2>&1
  while IFS= read -r file; do
    rel="${file#app/}"
    log="$reports/mutation/$rel.log"
    mkdir -p "$(dirname "$log")"
    xml="$reports/mutation/$rel.xml"
    python3 "$changed_tool" dart-config "$reports/manifest.json" "$reports/test-selection.json" "$file" "$xml"
    tool_status=0
    (cd "$tmp/wt/app" && mutation_test --coverage "$lcov" --format none "$xml" </dev/null) >"$log" 2>&1 || tool_status=$?
    cat "$log"
    python3 "$changed_tool" dart-mutation "$log" "$tool_status" || failed=1
  done <"$reports/flutter-files.txt"
  return "$failed"
}

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/check-quality.sh <go|flutter> [...]" >&2
  exit 2
fi
for stack in "$@"; do
  case "$stack" in
    go) run_go ;;
    flutter) run_flutter ;;
    *)
      echo "check-quality: unknown stack '$stack'" >&2
      exit 2
      ;;
  esac
done
