#!/bin/bash
# lib/common.sh — library index. Sources all focused modules.
[[ "${INFRA_LIB_LOADED:-}" = true ]] && return 0
INFRA_LIB_LOADED=true

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${INFRA_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

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
source "$_lib_dir/env.sh"
source "$_lib_dir/net.sh"
source "$_lib_dir/k3s.sh"
source "$_lib_dir/compose.sh"
source "$_lib_dir/validate.sh"
source "$_lib_dir/pvc.sh"
