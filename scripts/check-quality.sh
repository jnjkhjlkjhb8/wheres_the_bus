#!/usr/bin/env bash
# CRAP and mutation-testing gates over the code changed since QUALITY_BASE
# (default HEAD, i.e. the uncommitted work). Untouched legacy code is not
# gated. Expects coverage from the test run that precedes it: coverage.out
# for go, app/coverage/lcov.info for flutter.
#
# usage: scripts/check-quality.sh <go|flutter> [...]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

base="${QUALITY_BASE:-HEAD}"
# GitHub sends an all-zero "before" sha on a branch's first push.
if [[ "$base" =~ ^0+$ ]]; then
  base=HEAD^
fi
crap_max=8
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
cleanup() {
  git worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
  rm -rf "${tmp:?}"
}
trap cleanup EXIT

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
    # Skip stray archives; nothing a test needs is this large.
    [ -f "$f" ] && [ "$(wc -c <"$f")" -lt 5000000 ] || continue
    mkdir -p "$tmp/wt/$(dirname "$f")"
    cp "$f" "$tmp/wt/$f"
  done
  git diff --no-renames --name-only --diff-filter=D HEAD | while IFS= read -r f; do rm -f "${tmp:?}/wt/${f:?}"; done
  # Intent-to-add so new files show up in the worktree's own git diff.
  git -C "$tmp/wt" add -A -N
}

# changed_lines <pathspec>: "file start end" per added/modified hunk since
# base; an untracked file is reported whole as "file 0 0".
changed_lines() {
  git diff -M --unified=0 --no-color --no-ext-diff "$base" -- "$1" | awk '
    /^\+\+\+ / { file = substr($2, 3); next }
    /^@@ / {
      split(substr($3, 2), r, ",")
      n = (r[2] == "") ? 1 : r[2]
      if (n > 0 && file != "ev/null") print file, r[1], r[1] + n - 1
    }'
  git ls-files --others --exclude-standard -- "$1" | awk '{ print $0, 0, 0 }'
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
  local files
  # R100/C100 are pure moves: nothing in them changed, so they are not gated.
  files="$({ git diff --name-status --diff-filter=d "$base" -- '*.go' | awk '$1 !~ /^[RC]100$/ { print $NF }'
    git ls-files --others --exclude-standard -- '*.go'; } |
    grep -v -E '_test\.go$|\.pb\.go$' | sort -u || true)"
  if [ -z "$files" ]; then
    echo "no changed go files"
  else
    local cover_abs
    cover_abs="$(cd "$(dirname "$cover")" && pwd)/$(basename "$cover")"
    # shellcheck disable=SC2086 # newline-separated paths without spaces
    crap4go --test-command "cp '$cover_abs' target/coverage/coverage.out # {coverprofile}" $files | tee "$tmp/crap4go.txt"
    rm -rf target
    awk -v max="$crap_max" '
      /^-+$/ { body = 1; next }
      body && NF { if ($NF == "N/A" || $NF + 0 > max) { bad++; print "over " max ": " $0 } }
      END { exit bad > 0 }' "$tmp/crap4go.txt"
  fi

  echo "== quality: go mutation efficacy >= $mutation_min% on lines changed since $base =="
  GOBIN="$tools_bin" go install "github.com/go-gremlins/gremlins/cmd/gremlins@$gremlins_version"
  make_worktree
  mkdir -p "$tmp/gotmp"
  # gremlins v0.6.0 silently ignores the --threshold-* flags; only a config
  # file enforces them. It also derives mutant timeouts from the coverage
  # run, which the test cache can shrink to milliseconds, hence -count=1 and
  # the coefficient.
  cat >"$tmp/gremlins.yaml" <<EOF
unleash:
  threshold:
    efficacy: $mutation_min
    mutant-coverage: $mutation_min
  timeout-coefficient: 10
EOF
  # gremlins leaves its per-worker module copies in TMPDIR when it crashes.
  (cd "$tmp/wt" && GOFLAGS=-count=1 TMPDIR="$tmp/gotmp" gremlins unleash \
    --config "$tmp/gremlins.yaml" --diff "$base" --workers 2 --output-statuses lt .)
}

run_flutter() {
  local lcov="${QUALITY_LCOV:-app/coverage/lcov.info}"
  if [ ! -f "$lcov" ]; then
    echo "check-quality: $lcov missing; run (cd app && flutter test --coverage) first" >&2
    exit 1
  fi
  lcov="$(cd "$(dirname "$lcov")" && pwd)/$(basename "$lcov")"
  dart pub global activate crap4dart "$crap4dart_version" >/dev/null
  dart pub global activate mutation_test "$mutation_test_version" >/dev/null

  echo "== quality: dart CRAP <= $crap_max on methods changed since $base =="
  (cd app && crap4dart analyze --diff-base "$base" --threshold "$crap_max" --lcov "$lcov" </dev/null)
  local untracked
  untracked="$(git -C app ls-files --others --exclude-standard -- 'lib/*.dart' | tr '\n' ' ')"
  if [ -n "$untracked" ]; then
    # --diff-base only sees tracked files; a new file is changed throughout.
    # shellcheck disable=SC2086 # word list of paths without spaces
    (cd app && crap4dart analyze $untracked --threshold "$crap_max" --lcov "$lcov" </dev/null)
  fi

  echo "== quality: dart mutation score >= $mutation_min% on lines changed since $base =="
  local hunks="$tmp/dart-hunks"
  changed_lines 'app/lib/*.dart' | grep -v -E '^app/lib/(data/generated|generated|l10n)/|\.g\.dart ' >"$hunks" || true
  if [ ! -s "$hunks" ]; then
    echo "no changed dart lines"
    return
  fi
  make_worktree
  (cd "$tmp/wt/app" && flutter pub get >/dev/null)

  local file rel tests xml lines failed=0
  while IFS= read -r file; do
    rel="${file#app/}"
    # Tests that import the file; widget tests rarely sit at a mirrored path.
    tests="$(cd app && grep -rlF --include='*_test.dart' "${rel#lib/}" test | tr '\n' ' ' || true)"
    if [ -z "$tests" ]; then
      echo "$file: changed, but no test imports it" >&2
      failed=1
      continue
    fi
    xml="$tmp/${rel//\//_}.xml"
    lines=""
    while read -r _ start end; do
      [ "$start" = 0 ] || lines="$lines<lines begin=\"$start\" end=\"$end\"/>"
    done < <(grep "^$file " "$hunks")
    cat >"$xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mutations version="1.1">
  <files><file>$rel$lines</file></files>
  <commands>
    <command group="test" expected-return="0" working-directory="." timeout="600">flutter test $tests</command>
  </commands>
  <threshold failure="$mutation_min"><rating over="0" name="-"/></threshold>
</mutations>
EOF
    echo "-- $file (tests: $tests)"
    # mutation_test exits 0 when it aborts (e.g. the unmutated tests fail), so
    # only an explicit success line counts as a pass.
    (cd "$tmp/wt/app" && mutation_test --coverage "$lcov" --format none "$xml" </dev/null) | tee "$tmp/mutation.log" || true
    grep -q '^Success: true' "$tmp/mutation.log" || failed=1
  done < <(cut -d' ' -f1 "$hunks" | sort -u)
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
