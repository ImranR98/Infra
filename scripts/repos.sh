#!/bin/bash
# DESC: Shared repository lists for the daily Renovate routine. Sourced by
# renovate-daily.sh, wait-for-runs.sh, ci-notify.sh, and renovate.sh so the
# app set is defined exactly once. The lists live in config/VARS.env
# (gitignored; see config_template/VARS.env).
if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
if [ -f "$INFRA_ROOT/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1090,SC1091
    . "$INFRA_ROOT/config/VARS.env"
    set +a
fi

# App/ops repos: Renovate updates them, their CI tests, and (where they carry
# images) publishes.
# shellcheck disable=SC2034
APP_REPOS="${APP_REPOS:-}"
# Infra owns the nfs-server image; its deps are updated in a dedicated
# pre-infra Renovate pass so the rebuilt digest is captured the same day.
# shellcheck disable=SC2034
INFRA_REPO="${INFRA_REPO:-}"

if [ -z "$INFRA_REPO" ] || [[ "$INFRA_REPO" == *"<"* ]] || [ -z "$APP_REPOS" ] || [[ "$APP_REPOS" == *"<"* ]]; then
    echo "Error: set INFRA_REPO and APP_REPOS in config/VARS.env (see config_template/VARS.env)." >&2
    exit 1
fi

# shellcheck disable=SC2034
DERIVED_PATHS='["targets/srv0/k3s-base/nfs-server-src/**"]'
# shellcheck disable=SC2034
DERIVED_LABEL="derived-image"
# shellcheck disable=SC2034
DIGEST_LABEL="infra-digest-pin"
