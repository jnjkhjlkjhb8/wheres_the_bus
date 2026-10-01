#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
allowlist_dir="$repo_root/scripts/env-allowlists"
services=(router functions ingestor loader powersync motis)

usage() {
  echo "usage: $(basename "$0") <source-env-file> <output-dir>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
source_file="$1"
out_dir="$2"

[ -f "$source_file" ] || { echo "render-env.sh: source env file not found: $source_file" >&2; exit 1; }

umask 077
mkdir -p "$out_dir"
chmod 700 "$out_dir"

for service in "${services[@]}"; do
  allowlist="$allowlist_dir/${service}.txt"
  [ -f "$allowlist" ] || { echo "render-env.sh: missing allowlist $allowlist" >&2; exit 1; }
  out_file="$out_dir/${service}.env"
  tmp_file="$out_dir/.${service}.env.tmp.$$"
  : >"$tmp_file"
  while IFS= read -r key; do
    # Skip blank lines and #-comments in the allowlist file itself.
    case "$key" in
      ''|'#'*) continue ;;
    esac
    line=$(grep -m1 -E "^${key}=" "$source_file" || true)
    if [ -n "$line" ]; then
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$allowlist"
  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$out_file"
done

echo "render-env.sh: wrote ${services[*]/%/.env} to $out_dir (source: $source_file)"
