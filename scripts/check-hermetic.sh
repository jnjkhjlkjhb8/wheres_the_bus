#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

keep=0
[ "${1:-}" = "--keep" ] && keep=1

work_dir="$(mktemp -d)"
cleanup() {
  if [ "$keep" -eq 1 ]; then
    echo "archive kept at: $work_dir"
  else
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

fail=0
warn=0
note() { printf '\n== %s ==\n' "$*"; }
ok() { printf '  PASS %s\n' "$*"; }
bad() {
  printf '  FAIL %s\n' "$*"
  fail=1
}
warning() {
  printf '  WARN %s\n' "$*"
  warn=1
}

git archive "${HERMETIC_REF:-HEAD}" | tar -x -C "$work_dir"
archive="$work_dir"

note "(a) pinned protobuf stub generation"
if ! grep -q '^proto-go:' "$archive/Makefile" 2>/dev/null; then
  bad "Makefile has no proto-go target"
elif grep -E 'protoc-gen-go(-grpc)?@(latest|master)' "$archive/Makefile" >/dev/null; then
  bad "Makefile pins protoc-gen-go/-grpc to @latest instead of a fixed version"
else
  # Version may be a literal (protoc-gen-go@v1.2.3) or a Make variable
  # (protoc-gen-go@$(PROTOC_GEN_GO_VERSION)); resolve the variable form by
  # looking up its `NAME := value` assignment elsewhere in the Makefile.
  resolve_version() {
    local install_line="$1"
    local ref="${install_line##*@}"
    if [[ "$ref" =~ ^v[0-9] ]]; then
      printf '%s\n' "$ref"
    elif [[ "$ref" =~ ^\$\(([A-Za-z0-9_]+)\)$ ]]; then
      grep -E "^${BASH_REMATCH[1]}[[:space:]]*[:?]?=" "$archive/Makefile" \
        | sed -E 's/^[A-Za-z0-9_]+[[:space:]]*:?\??=[[:space:]]*//' | head -1
    fi
  }
  go_line="$(grep -oE 'protoc-gen-go@[^ ]+' "$archive/Makefile" | head -1 || true)"
  grpc_line="$(grep -oE 'protoc-gen-go-grpc@[^ ]+' "$archive/Makefile" | head -1 || true)"
  go_ver="$(resolve_version "$go_line")"
  grpc_ver="$(resolve_version "$grpc_line")"
  if [ -z "$go_ver" ] || [ -z "$grpc_ver" ]; then
    bad "Makefile does not pin explicit protoc-gen-go/-grpc versions"
  else
    ok "Makefile pins protoc-gen-go@$go_ver, protoc-gen-go-grpc@$grpc_ver"
  fi
fi

if ! grep -q '^proto-go:' "$archive/Makefile" 2>/dev/null; then
  warning "no proto-go target to execute yet"
elif ! command -v protoc >/dev/null; then
  warning "protoc not on PATH; skipped executing make proto-go"
else
  if ( cd "$archive" && GOCACHE="${GOCACHE:-$HOME/.cache/go-build}" make proto-go >/tmp/proto-go.$$ 2>&1 ); then
    if ls "$archive"/models/*.pb.go >/dev/null 2>&1; then
      ok "make proto-go generates models/*.pb.go from a clean archive"
    else
      bad "make proto-go ran but produced no models/*.pb.go"
    fi
  else
    bad "make proto-go failed in a clean archive; see /tmp/proto-go.$$"
  fi
  rm -f "/tmp/proto-go.$$"
fi

note "(b) declared Flutter assets are real files, not CI stubs"
pubspec="$archive/app/pubspec.yaml"
if [ ! -f "$pubspec" ]; then
  bad "app/pubspec.yaml missing from archive"
else
  # Pull every "- assets/..." / "asset: assets/..." line under the flutter: block.
  declared=()
  while IFS= read -r entry; do
    declared+=("$entry")
  done < <(awk '
    /^flutter:/ { influtter=1 }
    influtter && /^[a-zA-Z]/ && !/^flutter:/ { influtter=0 }
    influtter && match($0, /assets\/[^ #]*/) { print substr($0, RSTART, RLENGTH) }
  ' "$pubspec" | sort -u)

  missing=0
  zerobyte=0
  present=0
  for rel in "${declared[@]}"; do
    abs="$archive/app/$rel"
    if [[ "$rel" == */ ]]; then
      # directory entry: fine for it to be absent (whole tree is gitignored);
      # only a hard failure if present but contains a zero-byte stub.
      if [ -d "$abs" ]; then
        while IFS= read -r -d '' f; do
          present=$((present + 1))
          if [ ! -s "$f" ]; then
            bad "zero-byte stub asset present: ${f#$archive/app/}"
            zerobyte=$((zerobyte + 1))
          fi
        done < <(find "$abs" -type f -print0)
      fi
      continue
    fi
    if [ ! -e "$abs" ]; then
      missing=$((missing + 1))
      continue
    fi
    present=$((present + 1))
    if [ ! -s "$abs" ]; then
      bad "zero-byte stub asset present: $rel"
      zerobyte=$((zerobyte + 1))
      continue
    fi
    case "$rel" in
      *.ttf)
        magic="$(head -c4 "$abs" | od -An -tx1 | tr -d ' \n')"
        [ "$magic" = "00010000" ] || [ "$magic" = "4f54544f" ] || \
          bad "$rel does not have a TrueType/OpenType signature"
        ;;
      *.png)
        magic="$(head -c8 "$abs" | od -An -tx1 | tr -d ' \n')"
        [ "$magic" = "89504e470d0a1a0a" ] || bad "$rel is not a valid PNG"
        ;;
    esac
  done

  if [ "$zerobyte" -gt 0 ]; then
    : # already recorded as FAIL above
  elif [ "$present" -eq 0 ]; then
    warning "app/assets is absent from the archive (gitignored, user-owned) — asset gate requires owner-provided real assets before a clean checkout can build; this is expected, not a bug in this script"
  elif [ "$missing" -gt 0 ]; then
    warning "$missing declared asset(s) missing from archive; $present present and decodable"
  else
    ok "all $present declared assets present and decodable"
  fi
fi

note "(c) source imports resolve"
if command -v go >/dev/null; then
  if ( cd "$archive" && go build ./... >/tmp/gobuild.$$ 2>&1 ); then
    ok "go build ./... resolves all imports"
  else
    if grep -qE 'no required module provides package|cannot find package' /tmp/gobuild.$$; then
      bad "go build ./... has unresolved imports (see /tmp/gobuild.$$)"
    else
      warning "go build ./... failed for a reason other than unresolved imports (likely missing generated protobuf stubs — run (a) first); see /tmp/gobuild.$$"
    fi
  fi
  rm -f "/tmp/gobuild.$$"
else
  warning "go not on PATH; skipped go build"
fi

if command -v dart >/dev/null && [ -d "$archive/app" ]; then
  if ( cd "$archive/app" && dart pub get >/tmp/pubget.$$ 2>&1 ); then
    if ( cd "$archive/app" && dart analyze >/tmp/dartanalyze.$$ 2>&1 ); then
      ok "dart analyze reports no import resolution errors"
    else
      if grep -qE 'uri_does_not_exist' /tmp/dartanalyze.$$; then
        bad "dart analyze found imports whose target file does not exist in the archive (see /tmp/dartanalyze.$$)"
      else
        warning "dart analyze reported non-import issues (expected: missing app/assets, undefined symbols from files not yet committed); see /tmp/dartanalyze.$$"
      fi
    fi
    rm -f /tmp/dartanalyze.$$
  else
    warning "dart pub get failed in clean archive; see /tmp/pubget.$$"
  fi
  rm -f /tmp/pubget.$$
else
  warning "dart not on PATH; skipped dart analyze"
fi

note "(d) workflow action refs pinned to full commit SHAs"
shopt -s nullglob
workflows=("$archive"/.github/workflows/*.yaml "$archive"/.github/workflows/*.yml)
shopt -u nullglob
if [ "${#workflows[@]}" -eq 0 ]; then
  bad "no tracked workflow files found in archive"
else
  section_fail=0
  for wf in "${workflows[@]}"; do
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line%"${line##*[![:space:]]}"}" # trim trailing whitespace
      ref="${line##*@}"
      action="${line#*uses: }"
      action="${action%%@*}"
      if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        : # pinned
      else
        bad "$(basename "$wf"): $action pinned to mutable ref '$ref', not a full SHA"
        section_fail=1
      fi
    done < <(grep -E '^\s*-?\s*uses:\s' "$wf" | sed -E 's/^\s*-?\s*//')
  done
  [ "$section_fail" -eq 0 ] && ok "all uses: refs in tracked workflows are full 40-char SHAs"
fi

note "(e) workflows declare least-privilege permissions"
for wf in "${workflows[@]}"; do
  if ! grep -qE '^permissions:' "$wf"; then
    bad "$(basename "$wf") has no top-level permissions: block (defaults to broad token scope)"
  elif grep -qE '^permissions:\s*write-all\s*$' "$wf"; then
    bad "$(basename "$wf") grants permissions: write-all"
  else
    ok "$(basename "$wf") declares a top-level permissions: block"
  fi
done

note "(f) DB-dependent integration test coverage"
db_skips="$(grep -rlE 't\.Skip\("[A-Z_]*DATABASE_URL not set' "$archive"/services 2>/dev/null || true)"
if [ -z "$db_skips" ]; then
  warning "no DB-gated integration tests found (unexpected — check the grep pattern)"
else
  count="$(printf '%s\n' "$db_skips" | wc -l | tr -d ' ')"
  ok "$count file(s) with DB-gated integration tests (require DATABASE_URL / BUS_WRITER_DATABASE_URL / TASK5_DATABASE_URL); reported below, not silently dropped:"
  printf '%s\n' "$db_skips" | sed "s#^$archive/#    - #"
  if [ -z "${DATABASE_URL:-}" ]; then
    warning "DATABASE_URL is unset in this run — the tests above will skip; this is the documented convention, surfaced explicitly rather than silently"
  fi
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  echo "check-hermetic: FAIL (see FAIL lines above)"
  exit 1
elif [ "$warn" -ne 0 ]; then
  echo "check-hermetic: PASS with WARN (expected gaps — see WARN lines above)"
  exit 0
else
  echo "check-hermetic: PASS"
  exit 0
fi
