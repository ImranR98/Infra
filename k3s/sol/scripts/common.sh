#!/bin/bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"}"

get_sudo_cmd() {
	if command -v run0 &>/dev/null; then echo "run0"; else echo "sudo"; fi
}

source_env() {
	local vars_file="$ROOT_DIR/../../VARS.sh"
	if [ -f "$vars_file" ]; then
		source "$vars_file"
	else
		echo "Error: $vars_file not found" >&2
		exit 1
	fi

	MY_UID=$(id -u)
	[ "$MY_UID" -eq 0 ] && MY_UID=1000
	export MY_UID

	MAIN_NODE_NAME_LOWERCASE="${MAIN_NODE_NAME:-}"
	MAIN_NODE_NAME_LOWERCASE="$(echo "$MAIN_NODE_NAME_LOWERCASE" | tr '[:upper:]' '[:lower:]')"
	export MAIN_NODE_NAME_LOWERCASE
}

get_envsubst_vars() {
	local vars=""
	if [ -f "$ROOT_DIR/../../VARS.sh" ]; then
		vars=$(grep -oP 'export \K[A-Z_]+' "$ROOT_DIR/../../VARS.sh" | sed 's/^/$/' | tr '\n' ' ')
	fi
	# Also include runtime-computed vars
	for v in MY_UID MAIN_NODE_NAME_LOWERCASE; do
		vars="$vars \$$v"
	done
	echo "$vars"
}

generate_token() {
	local length="${1:-32}"
	openssl rand -hex "$length"
}
