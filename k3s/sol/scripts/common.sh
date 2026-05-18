#!/bin/bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"}"

source_env() {
	local vars_file="$ROOT_DIR/../../VARS.sh"
	if [ -f "$vars_file" ]; then
		source "$vars_file"
	else
		echo "Error: $vars_file not found" >&2
		exit 1
	fi

	# Validate that all variables from VARS templates are present in VARS.sh
	while IFS= read -r var; do
		if ! grep -q "^export $var=" "$vars_file"; then
			echo "VARS.sh is missing required variable: $var" >&2
			exit 1
		fi
	done < <(grep -hEo '^export [^=]+' "$ROOT_DIR/../../vars/VARS.common.sh" "$ROOT_DIR/../../vars/VARS.${TARGET:-$(basename "$ROOT_DIR")}.sh" 2>/dev/null | sed 's/^export //' | sort -u)

	MY_UID=$(id -u)
	[ "$MY_UID" -eq 0 ] && MY_UID=1000
	export MY_UID

	# Derive TARGET from the K3s directory name (k3s/<target>/) as fallback
	TARGET="${TARGET:-$(basename "$ROOT_DIR")}"
	export TARGET
}

get_envsubst_vars() {
	local vars=""
	if [ -f "$ROOT_DIR/../../VARS.sh" ]; then
		vars=$(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$ROOT_DIR/../../VARS.sh" | sed 's/^/$/' | tr '\n' ' ')
	fi
	# Also include runtime-computed vars
	for v in MY_UID TARGET; do
		vars="$vars \$$v"
	done
	echo "$vars"
}

