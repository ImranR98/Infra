#!/bin/bash
set -euo pipefail
# VARS file handling for Atlas.

resolve_vars_file() {
	local target="${1:-${TARGET:-}}"
	if [ -f "$ATLAS_ROOT/VARS.${target}.sh" ]; then
		echo "$ATLAS_ROOT/VARS.${target}.sh"
	elif [ -f "$ATLAS_ROOT/VARS.sh" ]; then
		echo "$ATLAS_ROOT/VARS.sh"
	fi
}

get_template_export_names() {
	local target="${1:-${TARGET:-}}"
	if [ -z "$target" ]; then return 0; fi
	grep -hEo '^export [A-Z_][A-Z_0-9]*' "$ATLAS_ROOT/targets/$target/VARS.template.sh" 2>/dev/null | sed 's/^export //' | sort -u
}

source_env() {
	local target="${TARGET:-${1:-}}"
	if [ -z "$target" ]; then
		echo "Error: TARGET must be set before calling source_env" >&2
		exit 1
	fi

	local vars_file; vars_file=$(resolve_vars_file "$target")
	if [ -z "$vars_file" ]; then
		echo "Error: neither VARS.${target}.sh nor VARS.sh found at $ATLAS_ROOT" >&2
		exit 1
	fi

	while IFS= read -r var; do
		if ! grep -q "^export $var=" "$vars_file"; then
			echo "Error: $vars_file is missing required variable: $var" >&2
			exit 1
		fi
	done < <(get_template_export_names "$target")

	source "$vars_file"

	if [ "$(id -u)" -eq 0 ]; then
		export MY_UID=1000
	else
		export MY_UID=$(id -u)
	fi

	export TARGET="$target"
}

get_envsubst_vars() {
	local vars=""

	local vars_file; vars_file=$(resolve_vars_file)
	if [ -n "$vars_file" ]; then
		vars="$vars $(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$vars_file" | tr '\n' ' ')"
	fi

	if [ -d "$ATLAS_ROOT/targets/$TARGET/k3s" ]; then
		vars="$vars $(grep -rhoE '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$ATLAS_ROOT/targets/$TARGET/k3s" --include='*.yaml' 2>/dev/null | sed 's/[${}]//g' | tr '\n' ' ')"
	fi

	for v in MY_UID TARGET COMPOSE_STATE_DIR DOCKER_GID FRPC_USER; do
		case " $vars " in *" $v "*) ;; *) vars="$vars $v" ;; esac
	done

	echo "$vars" | tr ' ' '\n' | sort -u | sed 's/^/$/' | tr '\n' ' '
}

ensure_envsubst_vars() { export ENVSUBST_VARS="${ENVSUBST_VARS:-$(get_envsubst_vars)}"; }
