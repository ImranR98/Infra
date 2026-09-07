#!/bin/bash
# scripts/common.sh — env bootstrap + shared helpers (_confirm/get_sudo_cmd/
# get_node_ip/wait_for_k3s_cluster) for the retained bash scripts.
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
[ -n "${PVC_BACKUP_DIR:-}" ] || export PVC_BACKUP_DIR="$INFRA_ROOT/k3s_state_backups"
if [ -z "${INFRA_INTERACTIVE:-}" ]; then
    if [ -t 0 ]; then export INFRA_INTERACTIVE=true; else export INFRA_INTERACTIVE=false; fi
fi
export TARGET="${TARGET:-}"

_confirm() {
    local prompt="${1:-Proceed?}" yn
    read -r -p "$prompt [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]]
}

get_sudo_cmd() {
    echo "sudo"
}

get_node_ip() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$iface" ] || return 1
    ip -4 addr show "$iface" | grep -oP 'inet \K[\d.]+'
}

wait_for_k3s_cluster() {
    local timeout_secs="${1:-150}"
    local max_tries=$(( timeout_secs / 5 ))
    for i in $(seq 1 "$max_tries"); do
        if kubectl get nodes >/dev/null 2>&1; then
            echo "Cluster ready."
            return 0
        fi
        echo "Waiting... ($i/$max_tries)"
        sleep 5
    done
    echo "Error: Could not connect to Kubernetes cluster after ${timeout_secs} seconds." >&2
    return 1
}

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
