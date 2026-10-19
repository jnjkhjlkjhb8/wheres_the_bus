#!/usr/bin/env bash
# CRAP and mutation gates for changed code (default) or every authored source.
# Coverage is produced by the corresponding quality Make target.
#
# usage: [QUALITY_SCOPE=all] scripts/check-quality.sh <go|flutter> [...]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

base="${QUALITY_BASE:-HEAD}"
scope="${QUALITY_SCOPE:-changed}"
phase="${QUALITY_PHASE:-all}"
case "$scope" in
  all|changed) ;;
  *) echo "check-quality: QUALITY_SCOPE must be changed or all" >&2; exit 2 ;;
esac
case "$phase" in
  all|crap|mutation) ;;
  *) echo "check-quality: QUALITY_PHASE must be all, crap or mutation" >&2; exit 2 ;;
esac
if [ "$scope" = changed ] && [ "$phase" != all ]; then
  echo "check-quality: QUALITY_PHASE applies only to QUALITY_SCOPE=all" >&2
  exit 2
fi
# GitHub sends an all-zero "before" sha on a branch's first push.
if [[ "$base" =~ ^0+$ ]]; then
  base=HEAD^
fi
crap_max=4
mutation_min=90
# Pinned like the other tools. crap4dart >= 0.10 needs Dart 3.13; bump it with
# the Flutter toolchain.
gremlins_version=v0.6.0
# crap4go has no tags; pinned to a commit.
crap4go_version=bee16dbdadb4
crap4dart_version=0.9.5
mutation_test_version=1.8.1
tools_bin="$repo_root/.tools/bin"
# Every tool below diffs through git, crap4dart and gremlins with their own
# fixed arguments. Copy detection keeps moved or copy-then-trimmed code from
# counting as new; relative paths let crap4dart, which runs inside app/, match
# git's output to its files.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=diff.renames GIT_CONFIG_VALUE_0=copies
export GIT_CONFIG_KEY_1=diff.relative GIT_CONFIG_VALUE_1=true
export PATH="$tools_bin:$PATH:$HOME/.pub-cache/bin"

tmp="$(mktemp -d)"
dart_worker_reports=""
cleanup() {
  if [ -n "$dart_worker_reports" ]; then
    python3 "$repo_root/scripts/quality-dart-shards.py" worker-end "$dart_worker_reports" "$$" || true
  fi
  git worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
  rm -rf "${tmp:?}"
}
trap cleanup EXIT

report_root="${QUALITY_REPORT_DIR:-$tools_bin/../quality/$scope}"
mkdir -p "$report_root"
report_root="$(cd "$report_root" && pwd)"
if [[ "$report_root" == "$repo_root/"* ]] && ! git check-ignore -q "$report_root/manifest.json"; then
  echo "check-quality: QUALITY_REPORT_DIR inside the repository must be gitignored" >&2
  exit 2
fi
report_tool="$repo_root/scripts/quality-report.py"
changed_tool="$repo_root/scripts/quality-changed.py"
shard_tool="$repo_root/scripts/quality-dart-shards.py"
inventory_root="$tmp/inventory"
if [ "$scope" = all ]; then
  python3 "$report_tool" inventory "$repo_root" "$inventory_root"
  for metadata in manifest.json go-files.txt go-packages.txt flutter-files.txt; do
    python3 "$shard_tool" publish "$inventory_root/$metadata" "$report_root/$metadata"
  done
  echo "complete authored Go/Dart scope: $report_root/manifest.json (phase: $phase)"
fi

# Mutation tools rewrite sources in place and gremlins copies the whole module
# per worker, so they run on a throwaway worktree: HEAD plus this tree's
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

run_all_go() {
  if [ "$phase" != crap ]; then
    python3 "$report_tool" go-preflight
  fi
  local cover="${QUALITY_GO_COVER:-coverage.out}"
  [ -f "$cover" ] || { echo "check-quality: $cover missing; run make quality-all" >&2; return 1; }
  cover="$(cd "$(dirname "$cover")" && pwd)/$(basename "$cover")"
  local key reports file package log config status failed=0 tool_status normalized_cover gremlins_tool
  GOBIN="$tools_bin" go install "github.com/go-gremlins/gremlins/cmd/gremlins@$gremlins_version"
  gremlins_tool="$(python3 "$repo_root/scripts/quality-gremlins.py")"
  key="$(python3 "$report_tool" fingerprint "$repo_root" go "$cover")"
  reports="$report_root/go/$key"
  mkdir -p "$reports/crap" "$reports/mutation"
  rm -f "$reports/complete.txt"
  cp "$inventory_root/manifest.json" "$reports/manifest.json"
  printf '%s\n' "$reports" >"$report_root/go-latest.txt"
  normalized_cover="$reports/coverage.normalized.out"
  python3 "$report_tool" normalize-go-coverage "$cover" "$normalized_cover" "$reports/coverage-normalization.json"
  GOBIN="$tools_bin" go install "github.com/unclebob/crap4go/cmd/crap4go@$crap4go_version"
  make_worktree
  # One-decimal formatting can turn 4.04 into a passing 4.0. Keep the pinned
  # calculation and widen only its report precision in a temporary tool copy.
  local tool_module
  tool_module="$(go list -m -f '{{.Dir}}' "github.com/unclebob/crap4go@$crap4go_version")"
  cp -R "$tool_module" "$tmp/crap4go-source"
  chmod -R u+w "$tmp/crap4go-source"
  python3 "$report_tool" go-precision "$tmp/crap4go-source/internal/crap/crap.go"
  printf 'crap4go %s; calculation unchanged; temporary report precision patch:\n' "$crap4go_version" >"$reports/crap4go-provenance.txt"
  diff -u "$tool_module/internal/crap/crap.go" "$tmp/crap4go-source/internal/crap/crap.go" >>"$reports/crap4go-provenance.txt" || [ "$?" = 1 ]
  (cd "$tmp/crap4go-source" && go build -o "$tmp/crap4go" ./cmd/crap4go)
  if [ "$phase" != mutation ]; then
  echo "== quality: all authored Go functions, CRAP <= $crap_max =="
  while IFS= read -r file; do
    log="$reports/crap/$file.log"
    mkdir -p "$(dirname "$log")"
    if [ "${QUALITY_RESUME:-1}" = 1 ] && [ -f "$log.pass" ]; then continue; fi
    rm -f "$log.pass"
    if (cd "$tmp/wt" && "$tmp/crap4go" --test-command "cp '$normalized_cover' target/coverage/coverage.out # {coverprofile}" "$file") >"$log" 2>&1 &&
      awk -v max="$crap_max" '
        /^-+$/ { body = 1; next }
        body && NF { if ($NF == "N/A" || $NF + 0 > max) { bad++; print "over " max ": " $0 } }
        END { exit !body || bad > 0 }' "$log"; then
      touch "$log.pass"
    else
      echo "$file: CRAP failed ($log)"
      failed=1
    fi
  done <"$inventory_root/go-files.txt"
  [ "$failed" = 0 ] || { echo "Go CRAP incomplete/failed; mutation has not run"; return 1; }
  fi
  if [ "$phase" = crap ]; then echo "Go CRAP passed; mutation remains unverified ($reports)"; return 0; fi
  echo "== quality: all authored Go mutants, efficacy and coverage >= $mutation_min% =="
  mkdir -p "$tmp/gotmp"
  python3 "$repo_root/scripts/quality-go-tests.py" collect "$tmp/wt" "$reports/test-dependencies.json"
  local baseline_cache
  baseline_cache="$(mktemp -d "$reports/baseline-run.XXXXXX")"
  while IFS= read -r package; do
    log="$reports/mutation/$package.log"
    mkdir -p "$(dirname "$log")"
    status="$log.pass"
    if [ "${QUALITY_RESUME:-1}" = 1 ] && [ -f "$status" ]; then continue; fi
    rm -f "$status" "$log.json"
    config="$tmp/gremlins.yaml"
    python3 "$report_tool" go-config "$reports/manifest.json" "$package" "$config"
    python3 "$repo_root/scripts/quality-go-tests.py" select "$reports/test-dependencies.json" "$package" "$log.tests.json"
    echo "-- Go mutation: $package (all dependent test roots; selection: $log.tests.json)"
    tool_status=0
    # Fixed database/Redis fixtures cannot be shared by concurrent mutants.
    (cd "$tmp/wt" && GOFLAGS="${GOFLAGS:-} -count=1 -p=1" QUALITY_GO_TEST_SELECTION="$log.tests.json" \
      QUALITY_GO_BASELINE_HELPER="$repo_root/scripts/quality-go-baseline.py" QUALITY_GO_BASELINE_CACHE="$baseline_cache" \
      QUALITY_GREMLINS_EXECUTABLE="$gremlins_tool" TMPDIR="$tmp/gotmp" "$gremlins_tool" unleash \
      --config "$config" --integration --coverpkg=./... --workers "${QUALITY_WORKERS:-1}" --output "$log.json" --output-statuses ltc .) >"$log" 2>&1 || tool_status=$?
    if python3 "$report_tool" validate-go "$log.json" "$log" "$tool_status"; then
      touch "$status"
    else
      echo "$package: mutation failed ($log)"
      failed=1
    fi
  done <"$inventory_root/go-packages.txt"
  if [ "$(python3 "$report_tool" fingerprint "$repo_root" go "$cover")" != "$key" ]; then
    echo 'Go inputs changed during the run; rerun before claiming completion' >&2
    failed=1
  fi
  if [ "$failed" = 0 ] && [ "$phase" = all ]; then echo 'all Go CRAP and mutation shards passed' >"$reports/complete.txt"; fi
  return "$failed"
}

run_all_flutter() {
  local lcov="${QUALITY_LCOV:-app/coverage/lcov.info}"
  python3 "$report_tool" validate-lcov "$repo_root" "$lcov" "${QUALITY_LCOV_PROVENANCE:-$lcov.quality.json}"
  [ -f "$lcov" ] || { echo "check-quality: $lcov missing; run make quality-all" >&2; return 1; }
  lcov="$(cd "$(dirname "$lcov")" && pwd)/$(basename "$lcov")"
  local key reports worker_reports file rel log xml mutation_status failed=0
  local shard_index="${QUALITY_DART_SHARD_INDEX:-0}" shard_count="${QUALITY_DART_SHARD_COUNT:-1}"
  local shard_files="$tmp/flutter-shard-files.txt"
  python3 "$shard_tool" select "$inventory_root/manifest.json" "$shard_index" "$shard_count" "$shard_files"
  local files=()
  local dart_crap_tool
  python3 "$shard_tool" locked "$report_root/dart-tools.lock" dart pub global activate crap4dart "$crap4dart_version" >"$tmp/flutter-crap-tool.log" 2>&1
  dart_crap_tool="$(python3 "$shard_tool" locked "$report_root/dart-tools.lock" python3 "$repo_root/scripts/quality-crap4dart.py")"
  key="$(python3 "$report_tool" fingerprint "$repo_root" flutter "$lcov")"
  reports="$report_root/flutter/$key"
  mkdir -p "$reports/mutation"
  if [ "$phase" != crap ]; then
    python3 "$shard_tool" worker-start "$reports" "$$" "$shard_index" "$shard_count"
    dart_worker_reports="$reports"
  fi
  python3 "$shard_tool" locked "$reports/completion.lock" rm -f "$reports/complete.txt"
  worker_reports="$(mktemp -d "$reports/worker-$shard_index-of-$shard_count.XXXXXX")"
  python3 "$shard_tool" publish "$inventory_root/manifest.json" "$reports/manifest.json"
  printf '%s\n' "$reports" >"$tmp/flutter-latest.txt"
  python3 "$shard_tool" publish "$tmp/flutter-latest.txt" "$report_root/flutter-latest.txt"
  cp "$tmp/flutter-crap-tool.log" "$worker_reports/crap-tool.log"
  cp "$repo_root/.tools/quality-runtime/crap4dart-$crap4dart_version-annotation-start/provenance.json" "$worker_reports/crap-tool-provenance.json"
  python3 "$shard_tool" locked "$report_root/dart-tools.lock" dart pub global activate mutation_test "$mutation_test_version" >"$worker_reports/mutation-tool.log" 2>&1
  while IFS= read -r file; do files+=("${file#app/}"); done <"$inventory_root/flutter-files.txt"
  if [ "$phase" != mutation ]; then
  echo "== quality: all authored Dart methods, CRAP <= $crap_max =="
  # Analyze ignores missing method coverage, so validate its structured results.
  (cd app && "$dart_crap_tool" analyze "${files[@]}" --format json --threshold "$crap_max" --lcov "$lcov" </dev/null) >"$worker_reports/crap.json" 2>"$worker_reports/crap.log" || failed=1
  python3 "$report_tool" validate-dart "$worker_reports/crap.json" "$worker_reports/crap-verdict.json" || failed=1
  [ "$failed" = 0 ] || { echo "Dart CRAP incomplete/failed; mutation has not run ($worker_reports)"; return 1; }
  for metadata in crap.json crap.log crap-verdict.json; do
    python3 "$shard_tool" publish "$worker_reports/$metadata" "$reports/$metadata"
  done
  fi
  if [ "$phase" = crap ]; then echo "Dart CRAP passed; mutation remains unverified ($reports)"; return 0; fi
  make_worktree
  (cd "$tmp/wt/app" && flutter pub get) >"$worker_reports/pub-get.log" 2>&1
  python3 "$report_tool" dart-tests "$repo_root" "$inventory_root/manifest.json" "$worker_reports/test-selection.json"
  python3 "$shard_tool" publish "$worker_reports/test-selection.json" "$reports/test-selection.json"
  echo "== quality: Dart mutation shard $shard_index/$shard_count; complete manifest retained, score >= $mutation_min% =="
  while IFS= read -r file; do
    rel="${file#app/}"
    log="$reports/mutation/$rel.log"
    mkdir -p "$(dirname "$log")"
    if [ "${QUALITY_RESUME:-1}" = 1 ] && python3 "$shard_tool" checkpoint "$log"; then continue; fi
    rm -f "$log.pass"
    xml="$reports/mutation/$rel.xml"
    python3 "$report_tool" dart-config "$worker_reports/test-selection.json" "$file" "$xml"
    mutation_status=0
    (cd "$tmp/wt/app" && mutation_test --coverage "$lcov" --format none "$xml" </dev/null) >"$log" 2>&1 || mutation_status=$?
    if python3 "$report_tool" validate-dart-mutation "$log" "$mutation_status" "$log.verdict.json"; then
      touch "$log.pass"
    else
      echo "$file: mutation failed ($log)"
      failed=1
    fi
  done <"$shard_files"
  if [ "$(python3 "$report_tool" fingerprint "$repo_root" flutter "$lcov")" != "$key" ]; then
    echo 'Dart inputs changed during the run; rerun before claiming completion' >&2
    failed=1
  fi
  python3 "$shard_tool" worker-end "$reports" "$$"
  dart_worker_reports=""
  if [ "$failed" = 0 ]; then
    if python3 "$shard_tool" complete "$inventory_root/manifest.json" "$reports" "$phase"; then
      echo "All authored Dart mutation checkpoints strictly verified ($reports)"
    elif [ "$shard_count" = 1 ]; then
      failed=1
    else
      echo "Dart shard passed; whole verification still incomplete ($reports/mutation-completion.json)"
    fi
  fi
  return "$failed"
}

run_go() {
  local cover="${QUALITY_GO_COVER:-coverage.out}"
  if [ ! -f "$cover" ]; then
    echo "check-quality: $cover missing; run go test -coverprofile=$cover ./... first" >&2
    exit 1
  fi
  echo "== quality: go CRAP <= $crap_max in files changed since $base =="
  # crap4go has no diff mode, threshold, or exit status, and reruns go test
  # itself: hand it the existing profile instead, limit it to changed files
  # (whole files, not just changed functions), and fail on any score over the
  # limit or N/A (a file with no coverage data at all).
  GOBIN="$tools_bin" go install "github.com/unclebob/crap4go/cmd/crap4go@$crap4go_version"
  local reports
  reports="$(mktemp -d "$report_root/go-changed.XXXXXX")"
  python3 "$changed_tool" inventory "$repo_root" "$base" "$reports"
  local files=() file
  while IFS= read -r file; do files+=("$file"); done <"$reports/go-files.txt"
  if [ "${#files[@]}" -eq 0 ]; then
    echo "no changed go files"
    return
  else
    local cover_abs
    cover_abs="$(cd "$(dirname "$cover")" && pwd)/$(basename "$cover")"
    local normalized tool_module
    normalized="$reports/coverage.normalized.out"
    python3 "$report_tool" normalize-go-coverage "$cover_abs" "$normalized" "$reports/coverage-normalization.json"
    tool_module="$(go list -m -f '{{.Dir}}' "github.com/unclebob/crap4go@$crap4go_version")"
    cp -R "$tool_module" "$tmp/crap4go-source"
    chmod -R u+w "$tmp/crap4go-source"
    python3 "$report_tool" go-precision "$tmp/crap4go-source/internal/crap/crap.go"
    printf 'crap4go %s; calculation unchanged; temporary report precision patch:\n' "$crap4go_version" >"$reports/crap4go-provenance.txt"
    diff -u "$tool_module/internal/crap/crap.go" "$tmp/crap4go-source/internal/crap/crap.go" >>"$reports/crap4go-provenance.txt" || [ "$?" = 1 ]
    (cd "$tmp/crap4go-source" && go build -o "$tmp/crap4go" ./cmd/crap4go)
    make_worktree
    (cd "$tmp/wt" && "$tmp/crap4go" --test-command "cp '$normalized' target/coverage/coverage.out # {coverprofile}" "${files[@]}") | tee "$reports/crap.log"
    awk -v max="$crap_max" '
      /^-+$/ { body = 1; next }
      body && NF { if ($NF == "N/A" || $NF + 0 > max) { bad++; print "over " max ": " $0 } }
      END { exit !body || bad > 0 }' "$reports/crap.log"
  fi

  echo "== quality: go mutation efficacy and coverage >= $mutation_min% on lines changed since $base =="
  GOBIN="$tools_bin" go install "github.com/go-gremlins/gremlins/cmd/gremlins@$gremlins_version"
  local gremlins_tool
  gremlins_tool="$(python3 "$repo_root/scripts/quality-gremlins.py")"
  make_worktree
  mkdir -p "$tmp/gotmp"
  # gremlins v0.6.0 silently ignores the --threshold-* flags; only a config
  # file enforces them. It also derives mutant timeouts from the coverage
  # run, which the test cache can shrink to milliseconds, hence -count=1 and
  # the coefficient.
  python3 "$changed_tool" go-config "$reports/manifest.json" "$tmp/gremlins.yaml"
  local tool_status=0
  # Shared DB/Redis fixtures require one mutant and one test package at a time.
  (cd "$tmp/wt" && GOFLAGS="${GOFLAGS:-} -count=1 -p=1" TMPDIR="$tmp/gotmp" "$gremlins_tool" unleash \
    --config "$tmp/gremlins.yaml" --diff "$base" --integration --coverpkg=./... \
    --workers "${QUALITY_WORKERS:-1}" --output "$reports/mutation.json" --output-statuses ltc .) >"$reports/mutation.log" 2>&1 || tool_status=$?
  cat "$reports/mutation.log"
  python3 "$report_tool" validate-go "$reports/mutation.json" "$reports/mutation.log" "$tool_status"

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
  local flavor_tests=()
  while IFS= read -r file; do [ -z "$file" ] || flavor_tests+=("$file"); done < <(python3 "$changed_tool" flavor-tests "$reports/test-selection.json")
  if [ "${#flavor_tests[@]}" -gt 0 ]; then
    python3 "$report_tool" lcov-snapshot "$repo_root" "$reports/flavor-source-inputs.json"
    (cd app && flutter test "${flavor_tests[@]}" --dart-define-from-file=env/quality-firebase.json \
      --coverage --coverage-path="$reports/enabled.lcov") >"$reports/enabled-tests.log" 2>&1
    python3 "$report_tool" merge-lcov "$repo_root" "$reports/flavor-source-inputs.json" \
      "$reports/coverage.merged.lcov" "$reports/coverage-provenance.json" "$lcov" "$reports/enabled.lcov"
    lcov="$reports/coverage.merged.lcov"
  fi
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
    go) if [ "$scope" = all ]; then run_all_go; else run_go; fi ;;
    flutter) if [ "$scope" = all ]; then run_all_flutter; else run_flutter; fi ;;
    *)
      echo "check-quality: unknown stack '$stack'" >&2
      exit 2
      ;;
  esac
done
