#!/bin/bash
# DESC: Run Renovate against ImranR98/Infra — opens update PRs on GitHub (manual). srv0 runs this automatically via the renovate CronJob; use this for on-demand runs.
set -euo pipefail
source "$INFRA_ROOT/scripts/common.sh"

# Universal VARS (dotenv, e.g. secrets/VARS.env — gitignored). Simple KEY="value"
# lines source fine in bash; set -a exports them like the old `export` prefixes.
UNIVERSAL_VARS_FILE=""
for _f in "$INFRA_ROOT/secrets/VARS.env" "$INFRA_ROOT/VARS.env"; do
    if [ -f "$_f" ]; then UNIVERSAL_VARS_FILE="$_f"; break; fi
done
if [ -n "$UNIVERSAL_VARS_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$UNIVERSAL_VARS_FILE"
    set +a
fi

if [ -z "${RENOVATE_GITHUB_TOKEN:-}" ]; then
    echo "Error: RENOVATE_GITHUB_TOKEN is not set." >&2
    echo "Add it to $INFRA_ROOT/secrets/VARS.env (gitignored):" >&2
    echo "  RENOVATE_GITHUB_TOKEN=\"<github-pat-with-repo-scope>\"" >&2
    exit 1
fi

# The gomod manager (WASM plugin) needs a Go toolchain when an update is
# pending — install it with: task <target>:prereqs
if ! command -v go >/dev/null 2>&1; then
    echo "Warning: 'go' not found — pending gomod updates will crash the run." >&2
    echo "Install with: ansible-playbook ansible/playbooks/prereqs.yaml (or let the srv0 renovate CronJob handle it)." >&2
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
