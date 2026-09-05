#!/bin/bash
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export INFRA_ROOT

if [ -t 0 ]; then
    INFRA_INTERACTIVE=true
else
    INFRA_INTERACTIVE=false
fi
export INFRA_INTERACTIVE

export COMPOSE_STATE_DIR="$INFRA_ROOT/current_target/compose_live_state"
export COMPOSE_STATE_BACKUP_DIR="$INFRA_ROOT/compose_state_backups"
export K3S_STATE_DIR="$INFRA_ROOT/current_target/k3s_live_state"
export PVC_BACKUP_DIR="$INFRA_ROOT/k3s_state_backups"

if [ "${1:-}" = "" ]; then
    echo "Usage: $0 <target> <command...>" >&2
    echo "Usage: $0 <command...>   # universal command (no target)" >&2
    echo "Run '$0 <target>' to see available commands." >&2
    exit 1
fi

# Mode detection: a directory under targets/ => target mode; a top-level
# command under commands/ => universal mode (no target, no target VARS).
export TARGET=""
if [ -d "$INFRA_ROOT/targets/$1" ]; then
    TARGET="$1"
    shift
elif [ -x "$INFRA_ROOT/commands/$1.sh" ] || [ -f "$INFRA_ROOT/commands/$1.py" ] || [ -d "$INFRA_ROOT/commands/$1" ]; then
    : # universal command — TARGET stays empty, args are passed through
else
    echo "Unknown target or command: $1" >&2
    echo "Available targets: $(cd "$INFRA_ROOT/targets" && printf '%s ' */ | sed 's|/||g')" >&2
    echo "Universal commands: $(cd "$INFRA_ROOT/commands" && printf '%s ' *.sh | sed 's/\.sh//g')" >&2
    exit 1
fi

source "$INFRA_ROOT/lib/common.sh"

if [ -n "$TARGET" ]; then
    # Warn if this machine's hostname does not match the target name
    if [ "$(hostname)" != "$TARGET" ]; then
        echo "Warning: hostname '$(hostname)' does not match target '$TARGET'." >&2
        echo "Deploying may apply the wrong configuration. Press Enter to continue." >&2
        if [ "$INFRA_INTERACTIVE" = true ]; then
            read -r
        fi
    fi

    vars_found=false
    _skip_source=false
    case "${1:-}" in
        compose) case "${2:-}" in
            generate-mtls-certs) _skip_source=true ;;
        esac ;;
    esac
    if [ -n "$(resolve_vars_file "$TARGET")" ]; then
        vars_found=true
        if [ "$_skip_source" != true ]; then
            source_env "$TARGET"
            export ENVSUBST_VARS="$(get_envsubst_vars)"
        fi
    fi

    # Set up MY_UID, DOCKER_GID, ENVSUBST_VARS for compose commands
    case "${1:-}" in compose)
            if [ "${2:-}" != "backup-state" ] && [ "${2:-}" != "generate-mtls-certs" ]; then
            if ! $vars_found && [ -f "$INFRA_ROOT/targets/$TARGET/VARS.template.sh" ]; then
                echo "No VARS.$TARGET.sh or VARS.sh found. Create VARS.$TARGET.sh with variables from targets/$TARGET/VARS.template.sh." >&2
                exit 1
            fi
            if [ -z "${MY_UID:-}" ]; then
                if [ "$(id -u)" -eq 0 ]; then
                    export MY_UID=1000
                else
                    export MY_UID=$(id -u)
                fi
            fi
            if [ -z "${DOCKER_GID:-}" ]; then
                DOCKER_GID="$(getent group docker | cut -d: -f3)" || true
                if [ -z "$DOCKER_GID" ]; then
                    echo "Error: docker group not found. Is Docker installed?" >&2
                    exit 1
                fi
                export DOCKER_GID
            fi
            if [ -z "${ENVSUBST_VARS:-}" ]; then
                export ENVSUBST_VARS="$(get_envsubst_vars)"
            fi
        fi
        ;;
    esac
fi

source "$INFRA_ROOT/lib/dispatch.sh"
infra_dispatch "$@"