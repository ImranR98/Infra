#!/bin/bash
# Common library for Atlas — sourced by atlas.sh and all command scripts.

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${ATLAS_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

source "$_lib_dir/packages.sh"
source "$_lib_dir/vars.sh"
source "$_lib_dir/domains.sh"
source "$_lib_dir/images.sh"
source "$_lib_dir/compose-gen.sh"
