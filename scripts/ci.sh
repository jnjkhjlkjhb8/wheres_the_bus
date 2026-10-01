#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/ci.sh <contracts|go|flutter|migrations|security|all> [...]" >&2
  exit 2
fi

run_contracts() {
  echo "== contracts: dependency boundaries =="
  ./scripts/check-dependency-boundaries.sh
  ./scripts/check-dependency-boundaries.sh --self-test
  echo "== contracts: file-size ratchet =="
  ./scripts/check-file-budgets.sh
  ./scripts/check-file-budgets.sh --self-test
  echo "== contracts: proto contract (buf build + breaking) =="
  ./scripts/check-proto-contract.sh
}

run_go() {
  echo "== go: lint (golangci-lint) =="
  make lint

  echo "== go: test =="
  # shellcheck disable=SC2086 # GO_TEST_ARGS is a caller-controlled word list
  if [ -n "${GO_JUNIT_FILE:-}" ]; then
    if ! command -v gotestsum >/dev/null 2>&1; then
      echo "ci.sh: GO_JUNIT_FILE=$GO_JUNIT_FILE set but gotestsum is not installed" >&2
      exit 1
    fi
    gotestsum --junitfile "$GO_JUNIT_FILE" -- -race ${GO_TEST_ARGS:-} ./...
  else
    go test -race ${GO_TEST_ARGS:-} ./...
  fi
}

run_flutter() {
  echo "== flutter: proto-dart stubs =="
  mkdir -p app/lib/data/generated
  PATH="$PATH:$HOME/.pub-cache/bin" protoc --dart_out=grpc:app/lib/data/generated -I models models/*.proto
  echo "== flutter: pub get =="
  (cd app && flutter pub get)
  echo "== flutter: analyze =="
  (cd app && PATH="$PATH:$HOME/.pub-cache/bin" flutter analyze --no-fatal-infos)
  echo "== flutter: test =="
  # shellcheck disable=SC2086 # FLUTTER_TEST_ARGS is a caller-controlled word list
  (cd app && flutter test ${FLUTTER_TEST_ARGS:-})
}

run_migrations() {
  echo "== migrations: replay gate =="
  ./scripts/check-migrations.sh
}

run_security() {
  echo "== security: gitleaks =="
  ./scripts/check-gitleaks.sh
  echo "== security: govulncheck =="
  ./scripts/check-govulncheck.sh
  echo "== security: guardrail tests present =="
  ./scripts/check-guardrail-tests-present.sh
  echo "== security: per-service env allowlist =="
  ./scripts/check-env-allowlist.sh
  echo "== security: effective compose contract =="
  ./scripts/check-compose-effective.sh
  echo "== security: release manifest =="
  ./scripts/check-release-manifest.sh
}

for profile in "$@"; do
  case "$profile" in
    contracts) run_contracts ;;
    go) run_go ;;
    flutter) run_flutter ;;
    migrations) run_migrations ;;
    security) run_security ;;
    all)
      run_contracts
      run_go
      run_flutter
      run_migrations
      run_security
      ;;
    *)
      echo "ci.sh: unknown profile '$profile'" >&2
      exit 2
      ;;
  esac
done
