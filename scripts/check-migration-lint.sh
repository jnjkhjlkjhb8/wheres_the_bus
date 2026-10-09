#!/usr/bin/env bash
# Backward-compatibility lint for migrations/ (ADR-0027). The previous release
# keeps running while a migration applies and after an automatic rollback, so a
# new migration may not drop, rename or retype anything it still reads, and may
# not take a long lock on a live table.
#
#   - Files listed in migrations/squawk-grandfathered.txt predate this gate and
#     are skipped.
#   - `*-contract.sql` files are the second half of an expand/contract change:
#     they may drop a table, a column or a NOT NULL. Renames and type changes
#     stay banned everywhere; they are expand/contract changes, not one statement.
#
# Usage: scripts/check-migration-lint.sh [--self-test]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

SQUAWK_VERSION=2.67.0
CONTRACT_ONLY_RULES=ban-drop-column,ban-drop-table,ban-drop-not-null
# --exclude on the command line replaces .squawk.toml's excluded_rules rather
# than adding to it, so contract files get both lists passed explicitly.
CONFIG_EXCLUDES="$(sed -n '/^excluded_rules/,/]/p' .squawk.toml | grep -oE '"[a-z-]+"' | tr -d '"' | paste -sd, -)"

squawk() {
    if [ -n "${SQUAWK_BIN:-}" ]; then
        "$SQUAWK_BIN" "$@"
    elif command -v npx >/dev/null 2>&1; then
        npx -y "squawk-cli@${SQUAWK_VERSION}" "$@"
    else
        echo "check-migration-lint: neither SQUAWK_BIN nor npx is available" >&2
        return 2
    fi
}

# lint_dir DIR GRANDFATHER_FILE -> exit status 0 when every new file passes.
lint_dir() {
    local dir="$1" grandfathered="$2" fail=0 checked=0 f name
    for f in "$dir"/*.sql; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        if grep -qxF "$name" "$grandfathered"; then
            continue
        fi
        checked=$((checked + 1))
        local args=(-c .squawk.toml --reporter gcc)
        case "$name" in
            *-contract.sql) args+=(--exclude "${CONFIG_EXCLUDES},${CONTRACT_ONLY_RULES}") ;;
        esac
        if ! squawk "${args[@]}" "$f"; then
            echo "  FAIL      $name"
            fail=1
        else
            echo "  OK        $name"
        fi
    done
    echo "check-migration-lint: linted $checked new file(s)"
    return "$fail"
}

self_test() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    printf 'old.sql\n' >"$tmp/grandfathered.txt"
    printf 'DROP TABLE legacy;\n' >"$tmp/old.sql"
    mkdir "$tmp/bad" "$tmp/good"
    cp "$tmp/old.sql" "$tmp/good/old.sql"
    cp "$tmp/old.sql" "$tmp/bad/old.sql"

    printf 'BEGIN;\nALTER TABLE IF EXISTS t DROP COLUMN IF EXISTS c;\nCOMMIT;\n' >"$tmp/good/2099-01-01-drop-c-contract.sql"
    printf 'CREATE INDEX CONCURRENTLY IF NOT EXISTS t_c_idx ON t (c);\n' >"$tmp/good/2099-01-02-index.sql"
    if ! lint_dir "$tmp/good" "$tmp/grandfathered.txt" >/dev/null; then
        echo "self-test: FAIL (a grandfathered drop, a contract drop or a concurrent index was rejected)" >&2
        return 1
    fi

    printf 'BEGIN;\nALTER TABLE IF EXISTS t DROP COLUMN IF EXISTS c;\nCOMMIT;\n' >"$tmp/bad/2099-01-01-drop-c.sql"
    if lint_dir "$tmp/bad" "$tmp/grandfathered.txt" >/dev/null 2>&1; then
        echo "self-test: FAIL (a drop outside a -contract file was accepted)" >&2
        return 1
    fi
    rm "$tmp/bad/2099-01-01-drop-c.sql"
    printf 'BEGIN;\nALTER TABLE IF EXISTS t RENAME COLUMN a TO b;\nCOMMIT;\n' >"$tmp/bad/2099-01-01-rename-contract.sql"
    if lint_dir "$tmp/bad" "$tmp/grandfathered.txt" >/dev/null 2>&1; then
        echo "self-test: FAIL (a rename in a -contract file was accepted)" >&2
        return 1
    fi
    echo "check-migration-lint: self-test PASS"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

echo "== migrations: squawk lint (backward compatibility) =="
lint_dir migrations migrations/squawk-grandfathered.txt
