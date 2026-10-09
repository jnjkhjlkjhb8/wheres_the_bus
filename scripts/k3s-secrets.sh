#!/usr/bin/env bash
# Builds and applies the k3s Secrets from the operator's private files
# (ADR-0027). Run on the operator's machine only: it needs the age private key,
# and plaintext never leaves a 0700 temp dir that is removed on exit.
#
#   seal <env-file> <secret-files-dir>
#       Renders one env Secret per service from <env-file> through
#       scripts/env-allowlists/, plus the infrastructure credentials
#       (REDIS_PASSWORD, POSTGRES_PASSWORD, MIGRATE_DATABASE_URL,
#       PGBACKREST_REPO1_*) and the GHCR pull credential (GHCR_PULL_USER,
#       GHCR_PULL_TOKEN: a read:packages token). It also builds the file Secrets from
#       <secret-files-dir>: firebase-sa.json, cloudflared.json,
#       powersync_key.pem and pgbackrest_ed25519. Everything is encrypted into
#       k8s/infra/secrets/*.enc.yaml.
#   apply
#       Decrypts every k8s/infra/secrets/*.enc.yaml and applies it to the
#       current kubectl context.
#   gen-powersync-key <out-file>
#       Writes a new 2048-bit PKCS#1 RSA key: the JWT/JWKS signing key that
#       every api Pod mounts read-only.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

NAMESPACE=bus
# <secret prefix>:<allowlist> — api and realtime still use the router and
# functions allowlists their compose services are named after.
SERVICES="api:router realtime:functions rider:rider pipeline:pipeline powersync:powersync motis:motis"
OUT_DIR=k8s/infra/secrets

# keys_env <env-file> <out> KEY[=NAME]... copies the listed keys, renaming
# KEY to NAME when given, so a Secret can carry e.g. MIGRATE_DATABASE_URL as
# DATABASE_URL.
keys_env() {
    local src="$1" out="$2"
    shift 2
    : >"$out"
    local spec key name line
    for spec in "$@"; do
        key="${spec%%=*}"
        name="${spec#*=}"
        line="$(grep -m1 -E "^${key}=" "$src" || true)"
        [ -n "$line" ] || die "$key missing from $src"
        printf '%s=%s\n' "$name" "${line#*=}" >>"$out"
    done
}

die() { echo "k3s-secrets: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

secret_yaml() { # name, then kubectl create secret generic flags
    local name="$1"
    shift
    kubectl create secret generic "$name" --namespace "$NAMESPACE" "$@" \
        --dry-run=client -o yaml
}

seal() {
    local env_file="$1" files_dir="$2"
    need sops
    need kubectl
    [ -f "$env_file" ] || die "env file not found: $env_file"
    [ -d "$files_dir" ] || die "secret files dir not found: $files_dir"
    if grep -q AGE_RECIPIENT_NOT_SET .sops.yaml; then
        die "set the age public key in .sops.yaml first"
    fi

    local tmp
    tmp="$(mktemp -d)"
    chmod 700 "$tmp"
    # Expanded now: $tmp is local to this function and unset when EXIT fires.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    local pair allowlists=""
    for pair in $SERVICES; do
        allowlists="$allowlists ${pair#*:}"
    done
    RENDER_SERVICES="$allowlists" scripts/render-env.sh "$env_file" "$tmp/env" >/dev/null

    mkdir -p "$OUT_DIR"
    for pair in $SERVICES; do
        secret_yaml "${pair%%:*}-env" --from-env-file="$tmp/env/${pair#*:}.env" >"$tmp/${pair%%:*}-env.yaml"
    done
    # Infrastructure credentials, read from the same env file.
    keys_env "$env_file" "$tmp/redis.env" REDIS_PASSWORD
    keys_env "$env_file" "$tmp/postgres.env" POSTGRES_PASSWORD
    keys_env "$env_file" "$tmp/migrate.env" MIGRATE_DATABASE_URL=DATABASE_URL
    keys_env "$env_file" "$tmp/pgbackrest.env" \
        PGBACKREST_REPO1_SFTP_HOST PGBACKREST_REPO1_SFTP_HOST_USER \
        PGBACKREST_REPO1_SFTP_HOST_FINGERPRINT PGBACKREST_REPO1_CIPHER_PASS
    secret_yaml redis-env --from-env-file="$tmp/redis.env" >"$tmp/redis-env.yaml"
    secret_yaml postgres-env --from-env-file="$tmp/postgres.env" >"$tmp/postgres-env.yaml"
    secret_yaml migrate-env --from-env-file="$tmp/migrate.env" >"$tmp/migrate-env.yaml"
    secret_yaml pgbackrest-env --from-env-file="$tmp/pgbackrest.env" >"$tmp/pgbackrest-env.yaml"
    keys_env "$env_file" "$tmp/ghcr.env" GHCR_PULL_USER GHCR_PULL_TOKEN
    # shellcheck disable=SC1091
    (. "$tmp/ghcr.env" && kubectl create secret docker-registry ghcr-pull --namespace "$NAMESPACE" \
        --docker-server=ghcr.io --docker-username="$GHCR_PULL_USER" --docker-password="$GHCR_PULL_TOKEN" \
        --dry-run=client -o yaml) >"$tmp/ghcr-pull.yaml"
    rm -f "$tmp/ghcr.env"
    local f
    for f in firebase-sa.json cloudflared.json powersync_key.pem pgbackrest_ed25519; do
        [ -f "$files_dir/$f" ] || die "missing $files_dir/$f"
    done
    secret_yaml firebase-sa --from-file=firebase-sa.json="$files_dir/firebase-sa.json" >"$tmp/firebase-sa.yaml"
    secret_yaml cloudflared --from-file=credentials.json="$files_dir/cloudflared.json" >"$tmp/cloudflared.yaml"
    secret_yaml powersync-key --from-file=powersync_key.pem="$files_dir/powersync_key.pem" >"$tmp/powersync-key.yaml"
    secret_yaml pgbackrest-sftp-key --from-file=id_ed25519="$files_dir/pgbackrest_ed25519" >"$tmp/pgbackrest-sftp-key.yaml"

    local plain name
    for plain in "$tmp"/*.yaml; do
        name="$(basename "$plain" .yaml)"
        # --filename-override only selects the .sops.yaml rule; sops never reads that path.
        # shellcheck disable=SC2094
        sops --encrypt --filename-override "$OUT_DIR/${name}.enc.yaml" "$plain" >"$OUT_DIR/${name}.enc.yaml"
    done
    echo "k3s-secrets: sealed $(find "$OUT_DIR" -name '*.enc.yaml' | wc -l | tr -d ' ') Secrets into $OUT_DIR"
}

apply() {
    need sops
    need kubectl
    local f found=0
    for f in "$OUT_DIR"/*.enc.yaml; do
        [ -e "$f" ] || continue
        found=1
        sops --decrypt "$f" | kubectl apply -f -
    done
    [ "$found" -eq 1 ] || die "no sealed Secrets in $OUT_DIR; run seal first"
}

gen_powersync_key() {
    local out="$1"
    need openssl
    [ ! -e "$out" ] || die "$out already exists; refusing to overwrite a signing key"
    (
        umask 077
        # api loads it with x509.ParsePKCS1PrivateKey, so it must be the
        # traditional "RSA PRIVATE KEY" form, not PKCS#8. -traditional is
        # OpenSSL 3 only; LibreSSL already writes PKCS#1.
        openssl genrsa -traditional -out "$out" 2048 2>/dev/null || openssl genrsa -out "$out" 2048 2>/dev/null
    )
    grep -q 'BEGIN RSA PRIVATE KEY' "$out" || { rm -f "$out"; die "openssl did not produce a PKCS#1 key"; }
    echo "k3s-secrets: wrote $out"
}

case "${1:-}" in
    seal) [ "$#" -eq 3 ] || die "usage: $0 seal <env-file> <secret-files-dir>"; seal "$2" "$3" ;;
    apply) apply ;;
    gen-powersync-key) [ "$#" -eq 2 ] || die "usage: $0 gen-powersync-key <out-file>"; gen_powersync_key "$2" ;;
    *) die "usage: $0 <seal|apply|gen-powersync-key> ..." ;;
esac
