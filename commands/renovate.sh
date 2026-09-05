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

exec npx --yes -p renovate renovate "$@"
