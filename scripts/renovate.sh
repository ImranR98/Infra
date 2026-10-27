#!/bin/bash
# DESC: Run Renovate manually for apps, Infra, or both — opens update PRs on
# GitHub. The in-cluster renovate-daily CronJob uses
# scripts/renovate-daily.sh; use this for on-demand runs.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
# shellcheck disable=SC1091
source "$INFRA_ROOT/scripts/common.sh"
# shellcheck disable=SC1091
. "$INFRA_ROOT/scripts/repos.sh"

usage() {
    cat <<'EOF'
Usage: renovate.sh [apps|infra|all|clear-cache] [renovate options...]

  apps         Run Renovate for the app/ops repos (see scripts/repos.sh).
  infra        Run Renovate only for ImranR98/Infra, then the CI digest.
  all          Run both sets (default).
  clear-cache  Delete Renovate's persistent package/datasource cache.

The scheduled routine (derived nfs pass -> apps -> config check -> merges ->
publish wait -> full Infra) is scripts/renovate-daily.sh; use this script for
on-demand runs.

Examples:
  bash scripts/renovate.sh apps --dry-run
  bash scripts/renovate.sh infra
  bash scripts/renovate.sh clear-cache
EOF
}

selection="${1:-all}"
case "$selection" in
    apps | infra | all) shift ;;
    clear-cache | --clear-cache) selection=clear-cache; shift ;;
    -h | --help)
        usage
        exit 0
        ;;
    --*) selection=all ;;
    *)
        echo "Error: unknown selection '$selection'." >&2
        usage >&2
        exit 1
        ;;
esac

# Clearing the cache must work without credentials and before Renovate starts.
if [ "$selection" = "clear-cache" ] && [ "${1:-}" != "" ]; then
    echo "Error: clear-cache takes no extra arguments." >&2
    exit 1
fi
if [ "$selection" = "clear-cache" ]; then
    cache_dir="${RENOVATE_CACHE_DIR:-$HOME/.cache/infra-renovate}"
    if [ -z "$cache_dir" ] || [ "$cache_dir" = "/" ]; then
        echo "Error: refusing to clear unsafe RENOVATE_CACHE_DIR '$cache_dir'." >&2
        exit 1
    fi
    cache_target="$cache_dir/renovate"
    if [ -e "$cache_target" ]; then
        rm -rf -- "$cache_target"
        echo "Cleared Renovate package cache: $cache_target"
    else
        echo "Renovate package cache already empty: $cache_target"
    fi
    exit 0
fi

case "$selection" in
    apps) repos="$APP_REPOS" ;;
    infra) repos="$INFRA_REPO" ;;
    all) repos="$APP_REPOS,$INFRA_REPO" ;;
esac

# Universal VARS (dotenv, config/VARS.env — gitignored; template:
# config_template/VARS.env). Simple KEY="value" lines source fine in bash;
# set -a exports them.
UNIVERSAL_VARS_FILE=""
if [ -f "$INFRA_ROOT/config/VARS.env" ]; then
    UNIVERSAL_VARS_FILE="$INFRA_ROOT/config/VARS.env"
fi
if [ -n "$UNIVERSAL_VARS_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$UNIVERSAL_VARS_FILE"
    set +a
fi

if [ -z "${RENOVATE_GITHUB_TOKEN:-}" ]; then
    echo "Error: RENOVATE_GITHUB_TOKEN is not set." >&2
    echo "Create $INFRA_ROOT/config/VARS.env from the template:" >&2
    echo "  cp $INFRA_ROOT/config_template/VARS.env $INFRA_ROOT/config/VARS.env" >&2
    echo "then set RENOVATE_GITHUB_TOKEN=\"<github-pat-with-repo-scope>\"." >&2
    exit 1
fi

# The gomod manager (WASM plugin) needs a Go toolchain when an update is
# pending — install it with scripts/prereqs.sh.
if ! command -v go >/dev/null 2>&1; then
    echo "Warning: 'go' not found — pending gomod updates will crash the run." >&2
    echo "Install with: scripts/prereqs.sh (or let the in-cluster renovate-daily CronJob handle it)." >&2
fi

export RENOVATE_TOKEN="$RENOVATE_GITHUB_TOKEN"
if [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    RENOVATE_HOST_RULES="$(node -e 'console.log(JSON.stringify([{matchHost:"docker.io",hostType:"docker",username:process.env.DOCKERHUB_USER,password:process.env.DOCKERHUB_TOKEN}]))')"
    export RENOVATE_HOST_RULES
fi
export RENOVATE_REPOSITORIES="$repos"

# Renovate's Docker datasource keeps the Docker Hub tag list for a hardcoded
# 90 days in the package cache. A mutable `latest` tag can then resolve to an
# old build and produce backwards digest PRs (e.g. the redis PR #305). Cap that
# namespace at 7 days; cacheTtlOverride is the supported global override and
# takes minutes.
if [ -z "${RENOVATE_CACHE_TTL_OVERRIDE:-}" ]; then
    # shellcheck disable=SC2089 # JSON literal, not shell quoting
    printf -v RENOVATE_CACHE_TTL_OVERRIDE '%s' '{"datasource-docker-hub-cache":10080}'
fi
# shellcheck disable=SC2090 # JSON literal, not shell quoting
export RENOVATE_CACHE_TTL_OVERRIDE

export LOG_LEVEL="${LOG_LEVEL:-info}"

# Attribute commits to the repo's configured git identity instead of Renovate's
# default (a Mend-owned email that GitHub flags as unverified).
GIT_NAME="$(git -C "$INFRA_ROOT" config user.name 2>/dev/null || true)"
GIT_EMAIL="$(git -C "$INFRA_ROOT" config user.email 2>/dev/null || true)"
if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
    export RENOVATE_GIT_AUTHOR="$GIT_NAME <$GIT_EMAIL>"
fi

# Renovate's auto-commits must not use the machine's personal git signing
# setup (commit.gpgsign + gpg.format=ssh has no signingKey/agent available).
# Renovate 44 has no signing-off option and simple-git blocks GIT_CONFIG_GLOBAL,
# so point HOME at a fresh temp dir: git then finds no global config at all.
# Caches stay under the real home (user-owned, persistent) for fast npx runs.
_orig_home="$HOME"
export npm_config_cache="${npm_config_cache:-$_orig_home/.npm}"
export RENOVATE_CACHE_DIR="${RENOVATE_CACHE_DIR:-$_orig_home/.cache/infra-renovate}"
HOME="$(mktemp -d)"
export HOME
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$RENOVATE_CACHE_DIR"

# Notifications only cover PRs opened after this timestamp.
RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

npx --yes -p renovate renovate "$@"

# Publish a notification for each PR this run opened. Dry runs create none and
# are skipped; a notification failure must not fail the run. The ntfy settings
# live in config/srv0/values.yaml (srv0 owns the ntfy service) — machines
# without that config skip with a warning.
dry_run=false
for arg in "$@"; do
    case "$arg" in
        --dry-run*) dry_run=true ;;
    esac
done
if [ "$dry_run" = true ]; then
    exit 0
fi

ntfy_values_file="$INFRA_ROOT/config/srv0/values.yaml"
if [ ! -f "$ntfy_values_file" ] || ! command -v yq >/dev/null 2>&1; then
    echo "Warning: $ntfy_values_file not readable (or yq missing) — skipping Renovate notifications." >&2
    exit 0
fi

ntfy_token="$(yq -r '.NTFY_WRITE_ONLY_ACCOUNT_TOKEN // ""' "$ntfy_values_file")"
ntfy_domain="$(yq -r '.SERVICES_DOMAIN // ""' "$ntfy_values_file")"
ntfy_target="$(yq -r '.TARGET // ""' "$ntfy_values_file")"
if [ -z "$ntfy_token" ] || [ -z "$ntfy_domain" ] || [ -z "$ntfy_target" ]; then
    echo "Warning: ntfy settings incomplete in $ntfy_values_file — skipping Renovate notifications." >&2
    exit 0
fi

export NTFY_URL="https://ntfy.$ntfy_domain"
export NTFY_TOPIC="${ntfy_target}_services_renovate"
export NTFY_TOKEN="$ntfy_token"

IFS=',' read -r -a repo_list <<<"$repos"
notify_args=()
for repo in "${repo_list[@]}"; do
    if [ -n "$repo" ]; then
        notify_args+=(--repo "$repo")
    fi
done

bash "$INFRA_ROOT/scripts/renovate-notify.sh" --since "$RUN_START" "${notify_args[@]}" ||
    echo "Warning: Renovate notifier failed." >&2

# The scheduled infra run reports failed app CI runs; do the same when this
# manual run includes Infra.
if [ "$selection" != "apps" ]; then
    bash "$INFRA_ROOT/scripts/ci-notify.sh" ||
        echo "Warning: CI notifier failed." >&2
fi
