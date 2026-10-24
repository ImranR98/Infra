#!/bin/bash
# DESC: In-cluster Renovate entrypoint used by the renovate-apps and
# renovate-infra CronJobs. Runs Renovate for RENOVATE_REPOSITORIES, notifies on
# PRs created/updated during the run, optionally reports failed app CI runs,
# and posts an ntfy message if Renovate itself fails.
set -euo pipefail

: "${RENOVATE_REPOSITORIES:?RENOVATE_REPOSITORIES is required}"
: "${NTFY_URL:?NTFY_URL is required}"
: "${NTFY_TOPIC:?NTFY_TOPIC is required}"
: "${NTFY_TOKEN:?NTFY_TOKEN is required}"

INFRA_ROOT="${INFRA_ROOT:-/repo}"
export INFRA_ROOT

RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# VARS.env is dotenv: set -a exports the simple KEY="value" lines.
set -a
# shellcheck disable=SC1091
. "$INFRA_ROOT/config/VARS.env"
set +a

export RENOVATE_TOKEN="$RENOVATE_GITHUB_TOKEN"
if [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    RENOVATE_HOST_RULES="$(node -e 'console.log(JSON.stringify([{matchHost:"docker.io",hostType:"docker",username:process.env.DOCKERHUB_USER,password:process.env.DOCKERHUB_TOKEN}]))')"
    export RENOVATE_HOST_RULES
fi
export LOG_LEVEL="${LOG_LEVEL:-info}"

# Attribute commits to the repo's configured git identity (synced .git/config;
# matches local runs). Read the file directly: `git -C /repo` trips git's
# dubious-ownership check (root-owned mount parents, unprivileged pod).
if git config -f "$INFRA_ROOT/.git/config" user.name >/dev/null 2>&1 &&
    git config -f "$INFRA_ROOT/.git/config" user.email >/dev/null 2>&1; then
    RENOVATE_GIT_AUTHOR="$(git config -f "$INFRA_ROOT/.git/config" user.name) <$(git config -f "$INFRA_ROOT/.git/config" user.email)>"
    export RENOVATE_GIT_AUTHOR
fi

notify_args=()
IFS=',' read -r -a repo_list <<<"$RENOVATE_REPOSITORIES"
for repo in "${repo_list[@]}"; do
    [ -n "$repo" ] && notify_args+=(--repo "$repo")
done

rc=0
renovate || rc=$?

# A notifier failure must not change Renovate's exit code.
bash "$INFRA_ROOT/scripts/renovate-notify.sh" --since "$RUN_START" "${notify_args[@]}" ||
    echo "Warning: Renovate notifier failed" >&2

# The infra run happens an hour after the app run; report app CI failures in
# the last 24h to the same ntfy topic. Failure here is non-fatal.
if [ "${RUN_CI_NOTIFY:-false}" = "true" ]; then
    bash "$INFRA_ROOT/scripts/ci-notify.sh" ||
        echo "Warning: CI notifier failed" >&2
fi

if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2016 # Node expands process.env, not the shell.
    RC="$rc" node -e '
      (async () => {
        const url = `${process.env.NTFY_URL.replace(/\/+$/, "")}/${process.env.NTFY_TOPIC}`;
        const res = await fetch(url, {
          method: "POST",
          headers: { Authorization: `Bearer ${process.env.NTFY_TOKEN}` },
          body: `Renovate ${process.env.RUN_LABEL || "run"} failed with exit ${process.env.RC}. Check the CronJob logs.`,
        });
        if (!res.ok) console.error(`ntfy publish failed: ${res.status} ${await res.text()}`);
      })().catch((err) => console.error(err.message));
    ' || echo "Warning: failure notification failed" >&2
fi

exit "$rc"
