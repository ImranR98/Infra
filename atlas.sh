#!/bin/bash
set -euo pipefail

ATLAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export ATLAS_ROOT

[ -t 0 ] && ATLAS_INTERACTIVE=true || ATLAS_INTERACTIVE=false
export ATLAS_INTERACTIVE

export COMPOSE_STATE_DIR="$ATLAS_ROOT/current_target/compose_live_state"
export COMPOSE_STATE_BACKUP_DIR="$ATLAS_ROOT/current_target/compose_state_backups"
export LONGHORN_BACKUP_DIR="$ATLAS_ROOT/current_target/k3s_longhorn_backups"

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

# ---- Built-in command shortcuts (eliminates thin wrapper scripts) ----

_builtin_cmd="${1:-}"
case "$_builtin_cmd" in
	validate)
		source "$ATLAS_ROOT/lib/validate.sh"
		validate "$TARGET"
		exit $?
		;;
	list-domains)
		list_domains "$TARGET"
		exit $?
		;;
esac

if [ "${1:-}" = "compose" ] && [ "${2:-}" = "old-images" ]; then
	old_images
	exit $?
fi

# ---- Command discovery and dispatch ----

CMD_PATH=""
CMD_ARGS=("$@")

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
	_err=false
	if [ $arg_idx -eq 0 ] && [ -z "${CMD_ARGS[0]:-}" ]; then
		:
	else
		echo "Unknown command: ${CMD_ARGS[*]:0:$arg_idx}${search_path:+$search_path/}${CMD_ARGS[$arg_idx]:-}" >&2
		echo ""
		_err=true
	fi
	echo "Available commands:"
	echo ""

	_list_flat() {
		local dir="$1" prefix="$2"
		[ -d "$dir" ] || return
		bash -c '
			shopt -s nullglob dotglob
			for f in "$1"/*.sh "$1"/*.py; do
				[ -f "$f" ] || continue
				printf "%s%s\n" "$2" "$(basename "${f%.*}")"
			done
		' _ "$dir" "$prefix"
	}

	_indent() { sort | while IFS= read -r l; do echo "  $l"; done; }

	_list_flat "$ATLAS_ROOT/commands" "" | _indent

	# Built-in commands (no wrapper script needed)
	echo "  list-domains"
	echo "  validate"

	for stack_dir in "$ATLAS_ROOT/commands"/*/; do
		[ -d "$stack_dir" ] || continue
		stack=$(basename "$stack_dir")
		[ -d "$ATLAS_ROOT/targets/$TARGET/$stack" ] || continue
		echo ""
		{
			_list_flat "$stack_dir" "$stack "
			[ "$stack" = "compose" ] && echo "  $stack old-images"
		} | _indent
		target_dir="$ATLAS_ROOT/targets/$TARGET/commands/$stack"
		if [ -d "$target_dir" ]; then
			echo ""
			_list_flat "$target_dir" "$stack " | _indent
		fi
	done
	$_err && exit 1 || exit 0
fi

exec ${CMD_RUNNER:-bash} "$CMD_PATH" "$@"
