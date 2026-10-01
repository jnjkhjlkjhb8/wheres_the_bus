#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

GITLEAKS_VERSION="v8.30.1"
tools_bin="$repo_root/.tools/bin"

echo "== gitleaks secret scan ($GITLEAKS_VERSION, tracked tree + history policy) =="

mkdir -p "$tools_bin"
# A `go install` build does not stamp `gitleaks version`; read the module
# version from the binary's build info instead.
if ! go version -m "$tools_bin/gitleaks" 2>/dev/null \
  | grep -q "github.com/zricethezav/gitleaks/v8[[:space:]]*$GITLEAKS_VERSION"; then
  echo "  installing gitleaks $GITLEAKS_VERSION into .tools/bin"
  GOBIN="$tools_bin" go install "github.com/zricethezav/gitleaks/v8@$GITLEAKS_VERSION"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
git archive HEAD | tar -x -C "$work_dir"

# Scan the exact release tree. History is intentionally scanned by the CI
# action with fetch-depth=0; this local gate must remain safe for developers
# whose repository history contains reviewed, expired findings.

# Config is taken from the working tree (not the archive) so a policy edit
# is testable before it is committed.
if "$tools_bin/gitleaks" dir "$work_dir" --config "$repo_root/.gitleaks.toml" \
  --no-banner --redact --exit-code 1; then
  echo "  OK   no secrets detected in the tracked tree"
  echo ""
  echo "RESULT: GREEN — gitleaks found no leaks."
else
  echo "  FAIL gitleaks flagged findings above (values redacted; rotate + purge, or add a reviewed .gitleaksignore entry)"
  echo ""
  echo "RESULT: RED — secrets detected."
  exit 1
fi
