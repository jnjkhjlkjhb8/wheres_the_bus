#!/usr/bin/env bash
# Writes manifest.json (relative path -> sha256) into the folder the router
# serves at /api/assets, so the app re-downloads only the files that changed.
#
#   scripts/gen-assets-manifest.sh app/assets-remote
#   rsync -av --delete app/assets-remote/ host:/srv/bus-assets/
set -euo pipefail

dir="${1:?usage: $0 <assets dir>}"
cd "$dir"
find . -type f ! -name manifest.json ! -name .DS_Store -print0 |
  sort -z |
  xargs -0 shasum -a 256 |
  python3 -c '
import json, sys
print(json.dumps({l.split(None, 1)[1].strip().removeprefix("./"): l.split()[0] for l in sys.stdin}, indent=2, sort_keys=True))
' > manifest.json
