#!/bin/bash
# lib/common.sh — library index + per-invocation environment for the remaining
# bash commands (k3s helm/pvc/preboot/renovate). The compose pipeline and
# config validation are Ansible playbooks now (ops/ansible/); VARS handling
# moved to lib/vars_validator.py (emits current_target/vars.yml for playbooks).
[[ "${INFRA_LIB_LOADED:-}" = true ]] && return 0
INFRA_LIB_LOADED=true

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# ---- always-on environment (exported so child processes in a chain see it) ----
# Pre-set values win (in-cluster pods ship INFRA_ROOT/PVC_BACKUP_DIR/MY_UID in
# their env and must not get host paths recomputed over them).
if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"
fi
export INFRA_ROOT
[ -n "${COMPOSE_STATE_DIR:-}" ] || export COMPOSE_STATE_DIR="$INFRA_ROOT/current_target/compose_live_state"
[ -n "${COMPOSE_STATE_BACKUP_DIR:-}" ] || export COMPOSE_STATE_BACKUP_DIR="$INFRA_ROOT/compose_state_backups"
[ -n "${K3S_STATE_DIR:-}" ] || export K3S_STATE_DIR="$INFRA_ROOT/current_target/k3s_live_state"
[ -n "${PVC_BACKUP_DIR:-}" ] || export PVC_BACKUP_DIR="$INFRA_ROOT/k3s_state_backups"
if [ -z "${INFRA_INTERACTIVE:-}" ]; then
    if [ -t 0 ]; then export INFRA_INTERACTIVE=true; else export INFRA_INTERACTIVE=false; fi
fi
export TARGET="${TARGET:-}"

# Retry a shell command string with configurable tries and delay
# args: tries delay command-string
retry() {
    local tries="${1:-30}"
    local delay="${2:-5}"
    shift 2
    for ((_=0; _<tries; _++)); do
        eval "$@" 2>/dev/null && return 0
        sleep "$delay"
    done
    return 1
}

_confirm() {
    local prompt="${1:-Proceed?}" yn
    read -r -p "$prompt [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]]
}

source "$_lib_dir/pkg.sh"
source "$_lib_dir/net.sh"
source "$_lib_dir/k3s.sh"

# ---- Target mode guards ------------------------------------------------------
if [ -n "$TARGET" ]; then
    # Warn if this machine's hostname does not match the target name
    if [ "$(hostname)" != "$TARGET" ]; then
        echo "Warning: hostname '$(hostname)' does not match target '$TARGET'." >&2
        echo "Deploying may apply the wrong configuration. Press Enter to continue." >&2
        if [ "$INFRA_INTERACTIVE" = true ]; then
            read -r || true
        fi
    fi

    if [ -z "${MY_UID:-}" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            export MY_UID=1000
        else
            MY_UID="$(id -u)"
            export MY_UID
        fi
    fi
fi
