#!/bin/bash
set -euo pipefail

ATLAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export ATLAS_ROOT

if [ -t 0 ]; then
	ATLAS_INTERACTIVE=true
else
	ATLAS_INTERACTIVE=false
fi
export ATLAS_INTERACTIVE

export COMPOSE_STATE_DIR="$ATLAS_ROOT/current_target/compose_live_state"
export COMPOSE_STATE_BACKUP_DIR="$ATLAS_ROOT/compose_state_backups"
export MAYASTOR_POOL_DIR="/var/local/mayastor-install/io-engine"
export PVC_BACKUP_DIR="$ATLAS_ROOT/current_target/k3s_pvc_backups"

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
if [ -n "$(resolve_vars_file "$TARGET")" ]; then
	source_env "$TARGET"
	vars_found=true
	export ENVSUBST_VARS="$(get_envsubst_vars)"
fi
if [ "$vars_found" = true ]; then
	DOCKER_GID="$(getent group docker | cut -d: -f3)" || true
	case "${1:-}" in
		compose|k3s)
			if [ -z "$DOCKER_GID" ] && [ "${2:-}" != "backup-state" ]; then
				echo "Error: docker group not found. Is Docker installed?" >&2
				exit 1
			fi
			[ -n "$DOCKER_GID" ] && export DOCKER_GID
			;;
	esac
elif [ -n "${1:-}" ]; then
	case "$1" in compose|k3s)
		if [ "${2:-}" != "backup-state" ]; then
			echo "No VARS.$TARGET.sh or VARS.sh found. Create VARS.$TARGET.sh with variables from targets/$TARGET/VARS.template.sh." >&2
			exit 1
		fi
		;;
	esac
fi

source "$ATLAS_ROOT/lib/dispatch.sh"
atlas_dispatch "$@"