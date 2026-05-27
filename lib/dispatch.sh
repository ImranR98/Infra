#!/bin/bash
set -euo pipefail

atlas_dispatch() {
	local cmd_args=("$@")

	case "${cmd_args[0]:-}" in
		validate)  validate "$TARGET"; exit $? ;;
		list-domains) list_domains "$TARGET"; exit $? ;;
	esac
	if [ "${cmd_args[0]:-}" = "compose" ] && [ "${cmd_args[1]:-}" = "old-images" ]; then
		docker images --no-trunc --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' | while IFS=$'\t' read -r image created; do
			created_ts=$(date -d "$created" +%s 2>/dev/null) || continue
			days=$(( ($(date +%s) - created_ts) / 86400 ))
			if [ "$days" -gt 60 ]; then
				printf "%-50s %3d days\n" "$image" "$days"
			fi
		done | sort -k2 -n
		exit $?
	fi

	local CMD_PATH="" CMD_RUNNER="bash" search_path="" found="" arg_idx=0
	local search_dirs=("targets/$TARGET/commands" "commands")

	while [ $arg_idx -lt ${#cmd_args[@]} ]; do
		local arg="${cmd_args[$arg_idx]}"; found=""
		for base in "${search_dirs[@]}"; do
			local shf="$ATLAS_ROOT/${base}${search_path:+/$search_path}/$arg.sh"
			local pyf="$ATLAS_ROOT/${base}${search_path:+/$search_path}/$arg.py"
			local dir="$ATLAS_ROOT/${base}${search_path:+/$search_path}/$arg"
			if [ -x "$shf" ]; then
				found="script"; CMD_PATH="$shf"; CMD_RUNNER="bash"; shift $((arg_idx + 1)); break 2
			elif [ -f "$pyf" ]; then
				found="script"; CMD_PATH="$pyf"; CMD_RUNNER="python3"; shift $((arg_idx + 1)); break 2
			elif [ -d "$dir" ]; then
				found="dir"; search_path="${search_path}${search_path:+/}$arg"; arg_idx=$((arg_idx + 1)); break
			fi
		done
		if [ "$found" = "script" ]; then break; fi
		if [ "$found" = "" ]; then break; fi
	done

	if [ -n "$CMD_PATH" ]; then exec "$CMD_RUNNER" "$CMD_PATH" "$@"; fi

	_atlas_help "$@"
}

_atlas_help() {
	local _err=false
	if [ $# -gt 0 ]; then
		echo "Unknown command: $*" >&2
		echo ""
		_err=true
	fi
	echo "Available commands:"
	echo ""
	for f in commands/*.sh commands/*.py; do
		[ -f "$f" ] || continue
		printf '  %s\n' "$(basename "${f%.*}")"
	done
	echo "  list-domains"
	echo "  validate"
	for stack in compose k3s; do
		[ -d "targets/$TARGET/$stack" ] || continue
		echo ""
		for f in "commands/$stack"/*.sh "commands/$stack"/*.py; do
			[ -f "$f" ] || continue
			printf '  %s %s\n' "$stack" "$(basename "${f%.*}")"
		done
	done
	if $_err; then exit 1; fi
	exit 0
}