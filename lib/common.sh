#!/bin/bash
# Common library for Atlas — sourced by atlas.sh and all command scripts.
# Provides all shared functionality as a single import point.

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${ATLAS_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

source "$_lib_dir/packages.sh"
source "$_lib_dir/vars.sh"
source "$_lib_dir/compose-gen.sh"
source "$_lib_dir/k3s-common.sh"
source "$_lib_dir/validate.sh"

# --- Inline function: list_domains (was lib/domains.sh) ---

list_domains() {
	local target="${1:-$TARGET}"
	local sd="${SERVICES_DOMAIN:-}"
	[ -z "$sd" ] && sd='$SERVICES_DOMAIN'

	_extract_hosts() {
		grep -rohP "Host\(\x60[^\x60]+\x60\)" "$@" 2>/dev/null | \
			sed "s/.*\x60\([^\x60]*\)\x60.*/\1/" | \
			grep -v '\.localhost'
	}

	if [ -d "$ATLAS_ROOT/targets/$target/k3s" ]; then
		_extract_hosts --include='*.yaml' "$ATLAS_ROOT/targets/$target/k3s" | \
			sed "s/\\\$SERVICES_DOMAIN/${sd}/g" | \
			sort -u
	fi

	if [ -f "$ATLAS_ROOT/targets/$target/compose/compose.yaml" ]; then
		sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$ATLAS_ROOT/targets/$target/compose/compose.yaml" | \
			sed "s/\\\$SERVICES_DOMAIN/${sd}/g" | \
			sort -u
	fi
}

# --- Inline function: wait_for_crds (was lib/wait-for-crd.sh) ---

wait_for_crds() {
	local timeout_secs="${1:-300}"
	local max_tries=$(( timeout_secs / 5 ))
	shift

	for crd in "$@"; do
		for _ in $(seq 1 "$max_tries"); do
			kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null && break
			sleep 5
		done
	done
}
