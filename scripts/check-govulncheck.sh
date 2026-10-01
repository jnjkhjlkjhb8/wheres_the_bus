#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

GOVULNCHECK_VERSION="v1.6.0"
tools_bin="$repo_root/.tools/bin"

echo "== govulncheck SCA scan ($GOVULNCHECK_VERSION) =="

mkdir -p "$tools_bin"
GOBIN="$tools_bin" go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"

if "$tools_bin/govulncheck" ./...; then
  echo "  OK   no known vulnerabilities on reachable call paths"
  echo ""
  echo "RESULT: GREEN — govulncheck clean."
else
  echo "  FAIL govulncheck reported reachable vulnerabilities above"
  echo ""
  echo "RESULT: RED — upgrade the affected modules."
  exit 1
fi
