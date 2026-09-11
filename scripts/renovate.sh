#!/bin/bash
# DESC: Run Renovate against ImranR98/Infra — opens update PRs on GitHub (manual). The in-cluster renovate CronJob runs this automatically; use this for on-demand runs.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

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
    echo "Install with: scripts/prereqs.sh (or let the in-cluster renovate CronJob handle it)." >&2
fi

export RENOVATE_TOKEN="$RENOVATE_GITHUB_TOKEN"
export RENOVATE_REPOSITORIES="ImranR98/Infra"
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

npx --yes -p renovate renovate "$@"
