#!/bin/bash
set -euo pipefail

ATLAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export ATLAS_ROOT

export COMPOSE_STATE_DIR="$ATLAS_ROOT/current_target/compose_live_state"
export COMPOSE_STATE_BACKUP_DIR="$ATLAS_ROOT/current_target/compose_state_backups"
export LONGHORN_BACKUP_DIR="$ATLAS_ROOT/current_target/k3s_longhorn_backups"

# ---- Target validation ----

if [ "${1:-}" = "" ]; then
	echo "Usage: $0 <target> <command...>" >&2
	echo "Run '$0 <target>' to see available commands." >&2
	exit 1
fi

if [ ! -d "$ATLAS_ROOT/targets/$1" ]; then
	echo "Unknown target: $1" >&2
	echo "Available targets: $(ls -1 "$ATLAS_ROOT/targets" | tr '\n' ' ')" >&2
	exit 1
fi
export TARGET="$1"
shift

# ---- Source VARS file ----

source "$ATLAS_ROOT/lib/common.sh"

vars_found=false
if [ -f "$ATLAS_ROOT/VARS.$TARGET.sh" ] || [ -f "$ATLAS_ROOT/VARS.sh" ]; then
	source_env "$TARGET"
	vars_found=true
fi
if [ "$vars_found" = true ]; then
	DOCKER_GID="$(getent group docker | cut -d: -f3)"
	if [ -z "$DOCKER_GID" ]; then echo "Error: docker group not found. Is Docker installed?" >&2; exit 1; fi
	export DOCKER_GID
	export FRPC_USER="${TARGET,,}"
elif [ -n "${1:-}" ]; then
	case "$1" in compose|k3s)
		echo "No VARS.$TARGET.sh or VARS.sh found. Create VARS.$TARGET.sh with variables from targets/$TARGET/VARS.template.sh." >&2
		exit 1 ;;
	esac
fi

# ---- Command discovery and dispatch ----

CMD_PATH=""
CMD_ARGS=("$@")

# Walk arguments left to right, trying both target-specific and generic directories.
# For each arg, check: targets/$TARGET/commands/<path>/<arg>.sh  OR  commands/<path>/<arg>.sh
# If .sh found → found the script, remaining args are its arguments.
# If directory found → descend into it and continue with next arg.
# Otherwise → error.

search_dirs=("targets/$TARGET/commands" "commands")
search_path=""
arg_idx=0

while [ $arg_idx -lt ${#CMD_ARGS[@]} ]; do
	arg="${CMD_ARGS[$arg_idx]}"
	found=""
	for base in "${search_dirs[@]}"; do
		full_sh="$ATLAS_ROOT/${base}${search_path:+/$search_path}/$arg.sh"
		full_py="$ATLAS_ROOT/${base}${search_path:+/$search_path}/$arg.py"
		dir="$ATLAS_ROOT/${base}${search_path:+/$search_path}/$arg"
		if [ -x "$full_sh" ]; then
			found="script"
			CMD_PATH="$full_sh"
			CMD_RUNNER="bash"
			shift $((arg_idx + 1))
			break 2
		elif [ -f "$full_py" ]; then
			found="script"
			CMD_PATH="$full_py"
			CMD_RUNNER="python3"
			shift $((arg_idx + 1))
			break 2
		elif [ -d "$dir" ]; then
			found="dir"
			search_path="${search_path}${search_path:+/}$arg"
			arg_idx=$((arg_idx + 1))
			break
		fi
	done
	if [ "$found" = "script" ]; then
		break
	elif [ "$found" = "" ]; then
		break
	fi
done

if [ -z "$CMD_PATH" ]; then
	# Fallback: try matching a common.sh function (hyphens→underscores)
	_fn_name="${CMD_ARGS[$arg_idx]:-}"
	_fn_name="${_fn_name//-/_}"
	if [ -n "$_fn_name" ] && declare -f "$_fn_name" >/dev/null 2>&1; then
		shift $((arg_idx + 1))
		"$_fn_name" "$TARGET" "$@"
		exit $?
	fi

	if [ $arg_idx -eq 0 ] && [ -z "${CMD_ARGS[0]:-}" ]; then
		# No command given — show available commands
		:
	else
		echo "Unknown command: ${CMD_ARGS[*]:0:$arg_idx}${search_path:+$search_path/}${CMD_ARGS[$arg_idx]:-}" >&2
	fi
	echo ""
	echo "Available commands:"
	(
		for base in "$ATLAS_ROOT/targets/$TARGET/commands" "$ATLAS_ROOT/commands"; do
			[ -d "$base" ] || continue
			bash -c '
				shopt -s nullglob dotglob
				list_dir() {
					local base="$1" prefix="$2"
					for f in "$base"/*.sh "$base"/*.py "$base"/*/; do
						if [ -f "$f" ]; then
							echo "$prefix$(basename "${f%.*}")"
						elif [ -d "$f" ]; then
							local dn; dn=$(basename "$f")
							list_dir "$f" "$prefix$dn/"
						fi
					done
				}
				list_dir "$1" ""
			' _ "$base"
		done
		echo "validate"
		echo "list-domains"
		echo "update-traefik-plugins"
		echo "compose/old-images"
	) | sort | while IFS= read -r line; do echo "  $line"; done
	exit 1
fi

exec $CMD_RUNNER "$CMD_PATH" "$@"
