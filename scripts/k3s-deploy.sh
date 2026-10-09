#!/usr/bin/env bash
# Rolls one release out to the k3s cluster in the current kubectl context
# (ADR-0027). The deploy workflow runs it on every main merge; the operator runs
# `bootstrap` once at cutover to record the first last-known-good snapshot.
#
#   deploy <release-manifest.json>
#       Refuses without a last-known-good snapshot. Runs the migrate-<commit>
#       Job, renders k8s/app with the release digests, applies it with prune,
#       waits for every Deployment, smoke-tests SMOKE_URL, then records the
#       render as the new snapshot. Any failure after the migration re-applies
#       the previous snapshot; the schema never rolls back.
#   bootstrap <release-manifest.json>
#       Same without the snapshot requirement, the migration Job and the
#       rollback: the operator has migrated and checked the release by hand.
#   render <release-manifest.json> <out.yaml>
#       Only the render; CI validates it with kubeconform.
#
# The release manifest is build-images' release-manifest.json:
#   {"commit": "<sha>", "images": {"api": "ghcr.io/...@sha256:...", ...}}
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

NAMESPACE=bus
LKG=bus-last-known-good
SELECTOR=app.kubernetes.io/part-of=bus-app
APP_IMAGES="api realtime rider pipeline"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
MIGRATE_TIMEOUT="${MIGRATE_TIMEOUT:-2400s}"
OUT_DIR="${OUT_DIR:-k8s/.release}"

die() { echo "k3s-deploy: $*" >&2; exit 1; }
log() { echo "k3s-deploy: $*"; }
kc() { kubectl -n "$NAMESPACE" "$@"; }

# render <release.json> <out.yaml>: k8s/app with every image pinned to its
# release digest. The overlay sits next to k8s/app because kustomize refuses an
# absolute resource path; the directory is gitignored.
render() {
    local release="$1" out="$2" name ref
    mkdir -p "$OUT_DIR"
    {
        echo 'resources: [../app]'
        echo 'images:'
        for name in $APP_IMAGES; do
            ref="$(jq -er --arg n "$name" '.images[$n]' "$release")" || die "release has no $name image"
            [[ "$ref" == *@sha256:* ]] || die "$name image is not pinned by digest: $ref"
            printf '  - name: ghcr.io/jnjkhjlkjhb8/bus-%s\n    newName: %s\n    digest: %s\n' \
                "$name" "${ref%@*}" "${ref#*@}"
        done
    } >"$OUT_DIR/kustomization.yaml"
    kubectl kustomize --load-restrictor LoadRestrictionsNone "$OUT_DIR" >"$out"
}

# apply_app <manifests.yaml>: apply and prune the app tree, then wait for it.
# Without the allowlist prune would list Secrets and PVCs, which ci-deployer
# cannot read.
apply_app() {
    kc apply -f "$1" --prune -l "$SELECTOR" \
        --prune-allowlist=apps/v1/Deployment \
        --prune-allowlist=batch/v1/CronJob \
        --prune-allowlist=core/v1/ConfigMap
    local d
    for d in $(kc get deployment -l "$SELECTOR" -o name); do
        kc rollout status "$d" --timeout "$ROLLOUT_TIMEOUT" || return 1
    done
}

migrate() {
    local release="$1" commit image job
    commit="$(jq -er .commit "$release")"
    image="$(jq -er .images.migrate "$release")"
    job="migrate-${commit:0:12}"
    if kc get job "$job" >/dev/null 2>&1; then
        # A re-run of the same release: the Job already ran (or is running).
        log "$job exists; waiting on it instead of creating another"
    else
        sed -e "s#MIGRATE_JOB_NAME#$job#" -e "s#MIGRATE_IMAGE#$image#" k8s/migrate/job.yaml | kc create -f -
    fi
    # Wait for whichever condition comes first; `wait` on one alone would sit
    # out the whole timeout when the other one happens.
    local deadline=$((SECONDS + ${MIGRATE_TIMEOUT%s}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(kc get job "$job" -o jsonpath='{.status.succeeded}')" = "1" ]; then
            kc logs "job/$job" --tail=-1 || true
            return 0
        fi
        if [ "$(kc get job "$job" -o jsonpath='{.status.failed}')" = "1" ]; then
            kc logs "job/$job" --tail=-1 || true
            die "$job failed; nothing was rolled out"
        fi
        sleep 5
    done
    kc logs "job/$job" --tail=-1 || true
    die "$job did not finish within $MIGRATE_TIMEOUT; nothing was rolled out"
}

smoke() {
    [ -n "${SMOKE_URL:-}" ] || { log "SMOKE_URL unset; skipping smoke test"; return 0; }
    # deferred: FDPL-113 gRPC unary + nearby stream smoke need an App Check debug token.
    curl -fsS --max-time 20 --retry 6 --retry-delay 5 --retry-all-errors "$SMOKE_URL/api/static-version" >/dev/null &&
        curl -fsS --max-time 20 "$SMOKE_URL/api/.well-known/jwks.json" | jq -e '.keys | length > 0' >/dev/null
}

save_lkg() {
    local manifests="$1" release="$2"
    kc create configmap "$LKG" --from-file=manifests.yaml="$manifests" \
        --from-file=release.json="$release" --dry-run=client -o yaml | kc apply -f -
    log "recorded $(jq -r .commit "$release") as last-known-good"
}

rollback() {
    local prev="$OUT_DIR/lkg.yaml"
    log "rolling back to last-known-good $(kc get configmap "$LKG" -o jsonpath='{.data.release\.json}' | jq -r .commit)"
    kc get configmap "$LKG" -o jsonpath='{.data.manifests\.yaml}' >"$prev"
    apply_app "$prev" || die "ROLLBACK FAILED: the cluster is between releases; fix by hand"
    die "release failed and was rolled back"
}

main() {
    local mode="$1" release="$2"
    command -v jq >/dev/null || die "jq is required"
    [ -f "$release" ] || die "release manifest not found: $release"
    local manifests="$OUT_DIR/manifests.yaml"

    if [ "$mode" = deploy ]; then
        kc get configmap "$LKG" >/dev/null 2>&1 ||
            die "no $LKG ConfigMap: run '$0 bootstrap' once before auto-deploy"
    fi
    render "$release" "$manifests"
    if [ "$mode" = bootstrap ]; then
        apply_app "$manifests" || die "bootstrap rollout failed"
        smoke || die "bootstrap smoke test failed"
        save_lkg "$manifests" "$release"
        return
    fi
    migrate "$release"
    if apply_app "$manifests" && smoke; then
        save_lkg "$manifests" "$release"
    else
        rollback
    fi
}

case "${1:-}" in
    render) [ "$#" -eq 3 ] || die "usage: $0 render <release-manifest.json> <out.yaml>"; render "$2" "$3" ;;
    deploy | bootstrap) [ "$#" -eq 2 ] || die "usage: $0 $1 <release-manifest.json>"; main "$1" "$2" ;;
    *) die "usage: $0 <deploy|bootstrap|render> <release-manifest.json>" ;;
esac
