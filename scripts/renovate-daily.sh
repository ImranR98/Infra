#!/bin/bash
# DESC: Daily Renovate routine, run by the renovate-daily CronJob on srv0.
#   1. Renovate Infra, nfs-server source only (derived image deps)
#   2. Renovate the app repos
#   3. Check app Renovate config conformance
#   4. Merge the derived-image PR once its checks pass
#   5. Merge every green app PR (squash)
#   6. Wait for app/derived GitHub Actions publishes to settle
#   7. Renovate Infra (full) so the new digests are pinned the same day
#   8. Merge Infra non-digest PRs after Validate
#   9. Notify: left-open PRs, per-PR messages, and one CI failure digest
# Flags: --dry-run (Renovate only, no merges/waits/notifications),
#        --derived-only (only step 1).
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi

# shellcheck disable=SC1091
. "$INFRA_ROOT/scripts/repos.sh"

dry_run=0
derived_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --derived-only) derived_only=1 ;;
        *)
            echo "Usage: $(basename "$0") [--dry-run] [--derived-only]" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -f "$INFRA_ROOT/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$INFRA_ROOT/config/VARS.env"
    set +a
fi

: "${RENOVATE_GITHUB_TOKEN:?RENOVATE_GITHUB_TOKEN is required}"
export RENOVATE_TOKEN="$RENOVATE_GITHUB_TOKEN"
export LOG_LEVEL="${LOG_LEVEL:-info}"

if [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    RENOVATE_HOST_RULES="$(node -e 'console.log(JSON.stringify([{matchHost:"docker.io",hostType:"docker",username:process.env.DOCKERHUB_USER,password:process.env.DOCKERHUB_TOKEN}]))')"
    export RENOVATE_HOST_RULES
fi

# Match scripts/renovate.sh: cap Renovate's Docker Hub tag-list cache at 7 days
# instead of its hardcoded 90, so a mutable `latest` cannot feed back an old
# digest.
if [ -z "${RENOVATE_CACHE_TTL_OVERRIDE:-}" ]; then
    # shellcheck disable=SC2089 # JSON literal, not shell quoting
    printf -v RENOVATE_CACHE_TTL_OVERRIDE '%s' '{"datasource-docker-hub-cache":10080}'
fi
# shellcheck disable=SC2090 # JSON literal, not shell quoting
export RENOVATE_CACHE_TTL_OVERRIDE

if git config -f "$INFRA_ROOT/.git/config" user.name >/dev/null 2>&1 &&
    git config -f "$INFRA_ROOT/.git/config" user.email >/dev/null 2>&1; then
    RENOVATE_GIT_AUTHOR="$(git config -f "$INFRA_ROOT/.git/config" user.name) <$(git config -f "$INFRA_ROOT/.git/config" user.email)>"
    export RENOVATE_GIT_AUTHOR
fi

notify_configured=0
if [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOPIC:-}" ] && [ -n "${NTFY_TOKEN:-}" ]; then
    notify_configured=1
fi

notify() {
    [ "$notify_configured" = 1 ] || return 0
    curl -fsS --max-time 15 --connect-timeout 5 -o /dev/null \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $1" \
        -d "$2" \
        "${NTFY_URL%/}/$NTFY_TOPIC" || echo "Warning: ntfy publish failed" >&2
}

renovate_args=()
[ "$dry_run" = 1 ] && renovate_args+=(--dry-run)

renovate_infra_derived() {
    RENOVATE_REPOSITORIES="$INFRA_REPO" \
        RENOVATE_INCLUDE_PATHS="$DERIVED_PATHS" \
        RENOVATE_DEPENDENCY_DASHBOARD=false \
        RENOVATE_PRUNE_STALE_BRANCHES=false \
        renovate "${renovate_args[@]}"
}

renovate_apps() {
    RENOVATE_REPOSITORIES="$APP_REPOS" renovate "${renovate_args[@]}"
}

renovate_infra_full() {
    RENOVATE_REPOSITORIES="$INFRA_REPO" renovate "${renovate_args[@]}"
}

if [ "$derived_only" = 1 ]; then
    renovate_infra_derived
    exit 0
fi

if [ "$dry_run" = 1 ]; then
    renovate_infra_derived
    renovate_apps
    renovate_infra_full
    exit 0
fi

RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
merge_report="$(mktemp)"
trap 'rm -f "$merge_report"' EXIT
rc=0

merge_prs() {
    local desc="$1"
    shift
    if ! bash "$INFRA_ROOT/scripts/merge-renovate-prs.sh" --report "$merge_report" "$@"; then
        echo "Error: $desc failed or timed out" >&2
        rc=1
    fi
}

echo "==> [1/9] Renovate Infra (nfs-server derived deps)"
if ! renovate_infra_derived; then
    echo "Error: derived Renovate run failed" >&2
    rc=1
fi

echo "==> [2/9] Renovate apps"
if ! renovate_apps; then
    echo "Error: app Renovate run failed" >&2
    rc=1
fi

echo "==> [3/9] Check app Renovate config conformance"
if ! config_out="$(bash "$INFRA_ROOT/scripts/check-app-configs.sh" 2>&1)"; then
    echo "$config_out"
    notify "Renovate daily: app Renovate config drift" "$config_out"
    rc=1
else
    echo "$config_out"
fi

echo "==> [4/9] Merge derived-image PR after checks"
merge_prs "derived-image merge" --repos "$INFRA_REPO" --only-label "$DERIVED_LABEL" --require-check test --merge-method merge --timeout 600

echo "==> [5/9] Merge app Renovate PRs after checks"
merge_prs "app PR merge" --repos "$APP_REPOS" --require-check test --merge-method squash --timeout 3600

echo "==> [6/9] Wait for publishes to settle"
wait_rc=0
bash "$INFRA_ROOT/scripts/wait-for-runs.sh" --since "$RUN_START" || wait_rc=$?
if [ "$wait_rc" -eq 2 ] || [ "$wait_rc" -eq 124 ]; then
    notify "Renovate daily: publish wait timed out" "A GitHub Actions run was still pending after the wait timeout. The full Infra pass ran anyway."
    # Non-fatal: the full pass still runs and the next run catches up.
elif [ "$wait_rc" -ne 0 ]; then
    echo "Error: publish wait failed" >&2
    rc=1
fi

echo "==> [7/9] Renovate Infra (full)"
if ! renovate_infra_full; then
    echo "Error: full Infra Renovate run failed" >&2
    rc=1
fi

echo "==> [8/9] Merge Infra non-digest PRs after Validate"
merge_prs "Infra non-digest merge" --repos "$INFRA_REPO" --skip-label "$DIGEST_LABEL,$DERIVED_LABEL" --require-check validate --merge-method merge --timeout 900

echo "==> [9/9] Notifications"
if [ "$notify_configured" = 1 ]; then
    if [ -s "$merge_report" ]; then
        left_open="$(grep -E '^left-open' "$merge_report" | cut -f2- || true)"
        if [ -n "$left_open" ]; then
            notify "Renovate daily: PRs left open" "$left_open"
        fi
    fi
    repos=()
    IFS=',' read -r -a app_list <<<"$APP_REPOS"
    for repo in "${app_list[@]}"; do
        [ -n "$repo" ] && repos+=(--repo "$repo")
    done
    repos+=(--repo "$INFRA_REPO")
    bash "$INFRA_ROOT/scripts/renovate-notify.sh" --since "$RUN_START" "${repos[@]}" ||
        echo "Warning: Renovate notifier failed" >&2
    bash "$INFRA_ROOT/scripts/ci-notify.sh" || echo "Warning: CI notifier failed" >&2
else
    echo "NTFY_* not set; skipping notifications"
fi

if [ "$rc" -ne 0 ]; then
    notify "Renovate daily failed" "One or more phases failed (exit $rc). Check the renovate-daily job logs."
fi
exit "$rc"
