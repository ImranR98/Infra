#!/bin/bash
# lib/common.sh — library index. Sources all focused modules.
[[ "${INFRA_LIB_LOADED:-}" = true ]] && return 0
INFRA_LIB_LOADED=true

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${INFRA_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

source "$_lib_dir/pkg.sh"
source "$_lib_dir/env.sh"
source "$_lib_dir/net.sh"
source "$_lib_dir/k3s.sh"
source "$_lib_dir/compose.sh"
source "$_lib_dir/validate.sh"
source "$_lib_dir/retry.sh"
source "$_lib_dir/pvc.sh"
