#!/bin/bash
# Common library for Atlas — sourced by atlas.sh and all command scripts.
# Provides all shared functionality as a single import point.
#
# Modules (sourced in dependency order):
#   packages.sh      — Package manager detection & helpers (apt/dnf/rpm-ostree)
#   vars.sh           — VARS file resolution, envsubst variable discovery
#   domains.sh        — DNS domain extraction from K3s/Compose configs
#   images.sh         — Old Docker image reporting
#   compose-gen.sh    — Compose YAML rendering & config file generation
#   k3s-common.sh     — K3s installer download, firewall helpers
#   validate.sh       — Stack validation (K3s & Compose)
#   wait-for-crd.sh   — CRD wait loop for post-apply hooks

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${ATLAS_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

source "$_lib_dir/packages.sh"
source "$_lib_dir/vars.sh"
source "$_lib_dir/domains.sh"
source "$_lib_dir/images.sh"
source "$_lib_dir/compose-gen.sh"
source "$_lib_dir/k3s-common.sh"
source "$_lib_dir/validate.sh"
source "$_lib_dir/wait-for-crd.sh"
