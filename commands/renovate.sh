#!/bin/bash
# DESC: Run Renovate against ImranR98/Infra — opens update PRs on GitHub (manual)
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
source_universal_env

if [ -z "${RENOVATE_GITHUB_TOKEN:-}" ]; then
    echo "Error: RENOVATE_GITHUB_TOKEN is not set." >&2
    echo "Add it to $INFRA_ROOT/secrets/VARS.sh (gitignored):" >&2
    echo "  export RENOVATE_GITHUB_TOKEN=\"<github-pat-with-repo-scope>\"" >&2
    exit 1
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
# so point HOME at an empty dir: git then finds no global config at all.
# Keep the npm cache reachable for fast npx startup.
export npm_config_cache="${npm_config_cache:-$HOME/.npm}"
export RENOVATE_CACHE_DIR="${RENOVATE_CACHE_DIR:-/tmp/infra-renovate-cache}"
mkdir -p /tmp/infra-renovate-home "$RENOVATE_CACHE_DIR"
export HOME="/tmp/infra-renovate-home"

exec npx --yes -p renovate renovate "$@"
