#!/bin/bash
# DESC: Shared repository lists and local Renovate credentials. Sourced by
# renovate.sh and the renovate-pr-ops helpers so the app set and token are
# defined exactly once. The values live in config/srv0/values.yaml — the same
# values the scheduled renovate-daily CronJob renders into its secret
# (gitignored; template: targets/srv0/config_template/values.yaml).
if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi

_values_file="$INFRA_ROOT/config/srv0/values.yaml"
if [ -f "$_values_file" ]; then
    APP_REPOS="$(yq -r '.APP_REPOS // ""' "$_values_file")"
    INFRA_REPO="$(yq -r '.INFRA_REPO // ""' "$_values_file")"
    if [ -z "${RENOVATE_GITHUB_TOKEN:-}" ]; then
        RENOVATE_GITHUB_TOKEN="$(yq -r '.RENOVATE_GITHUB_TOKEN // ""' "$_values_file")"
    fi
    if [ -z "${DOCKERHUB_USER:-}" ]; then
        DOCKERHUB_USER="$(yq -r '.DOCKERHUB_USER // ""' "$_values_file")"
    fi
    if [ -z "${DOCKERHUB_TOKEN:-}" ]; then
        DOCKERHUB_TOKEN="$(yq -r '.DOCKERHUB_TOKEN // ""' "$_values_file")"
    fi
fi

# shellcheck disable=SC2034
APP_REPOS="${APP_REPOS:-}"
# shellcheck disable=SC2034
INFRA_REPO="${INFRA_REPO:-}"
RENOVATE_GITHUB_TOKEN="${RENOVATE_GITHUB_TOKEN:-}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
export RENOVATE_GITHUB_TOKEN DOCKERHUB_USER DOCKERHUB_TOKEN
