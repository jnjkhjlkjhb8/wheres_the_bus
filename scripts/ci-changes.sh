#!/usr/bin/env bash
# Prints `go=true|false` and `flutter=true|false` for the files changed since
# $1, in GITHUB_OUTPUT form. Errs toward running: an unknown base (new branch,
# force-push that dropped the old tip) or a change to CI itself runs both.
set -euo pipefail

base="${1:-}"
if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  echo "go=true"
  echo "flutter=true"
  exit 0
fi

# --no-renames lists both paths of a move; with rename detection a file moved
# from services/ into app/ would show only its app/ path and skip go.
files=$(git diff --no-renames --name-only "$base" HEAD)
shared='^(\.github/workflows/|scripts/|Makefile$|models/)'

go=false
flutter=false
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$f" =~ $shared ]]; then
    go=true
    flutter=true
  elif [[ "$f" == app/* ]]; then
    flutter=true
  elif [[ "$f" != *.md ]]; then
    # Anything outside app/ may feed the Go build, the DB, or the images.
    go=true
  fi
done <<<"$files"

echo "go=$go"
echo "flutter=$flutter"
