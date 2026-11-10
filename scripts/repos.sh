#!/bin/bash
# DESC: Shared repository lists for Renovate. Sourced by renovate.sh and the
# renovate-pr-ops helpers so the app set is defined exactly once. The lists
# live in config/srv0/values.yaml — the same values the scheduled renovate-daily
# CronJob renders into its secret (gitignored; template:
# targets/srv0/config_template/values.yaml). config/VARS.env supplies the token
# and other local credentials only.
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
# images) publishes. Infra owns the nfs-server image and the deployment
# manifests.
_values_file="$INFRA_ROOT/config/srv0/values.yaml"
if [ -f "$_values_file" ]; then
    APP_REPOS="$(yq -r '.APP_REPOS // ""' "$_values_file")"
    INFRA_REPO="$(yq -r '.INFRA_REPO // ""' "$_values_file")"
fi

# shellcheck disable=SC2034
APP_REPOS="${APP_REPOS:-}"
# shellcheck disable=SC2034
INFRA_REPO="${INFRA_REPO:-}"
