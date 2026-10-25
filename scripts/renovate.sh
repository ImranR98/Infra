#!/bin/bash
# DESC: Run Renovate manually for apps, Infra, or both — opens update PRs on
# GitHub. The in-cluster renovate-apps/renovate-infra CronJobs use
# scripts/renovate-in-cluster.sh; use this for on-demand runs.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    cat <<'EOF'
Usage: renovate.sh [apps|infra|all] [renovate options...]

  apps   Run Renovate only for the six apps, DSCPLN, and dscpln-config.
  infra  Run Renovate only for ImranR98/Infra, then the app CI digest.
  all    Run both sets (default).

The failed app-Renovate-PR watcher remains separate:
  bash scripts/app-renovate-watch.sh

Examples:
  bash scripts/renovate.sh apps --dry-run
  bash scripts/renovate.sh infra
EOF
}

selection="${1:-all}"
case "$selection" in
    apps | infra | all) shift ;;
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

apps_repos="ImranR98/dscpln-config,ImranR98/DSCPLN,ImranR98/PixelNtfy,ImranR98/ISBN-Lookup,ImranR98/apps.obtainium.imranr.dev,ImranR98/our-times,ImranR98/order-manager,ImranR98/Logtfy"
infra_repos="ImranR98/Infra"
case "$selection" in
    apps) repos="$apps_repos" ;;
    infra) repos="$infra_repos" ;;
    all) repos="$apps_repos,$infra_repos" ;;
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
    echo "Install with: scripts/prereqs.sh (or let the in-cluster renovate-apps/renovate-infra CronJobs handle it)." >&2
fi

export RENOVATE_TOKEN="$RENOVATE_GITHUB_TOKEN"
if [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    RENOVATE_HOST_RULES="$(node -e 'console.log(JSON.stringify([{matchHost:"docker.io",hostType:"docker",username:process.env.DOCKERHUB_USER,password:process.env.DOCKERHUB_TOKEN}]))')"
    export RENOVATE_HOST_RULES
fi
export RENOVATE_REPOSITORIES="$repos"
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
    CI_REPOS="$apps_repos" bash "$INFRA_ROOT/scripts/ci-notify.sh" ||
        echo "Warning: CI notifier failed." >&2
fi
