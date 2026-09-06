#!/bin/bash
# lib/common.sh — library index + per-invocation environment bootstrap.
# Sources all focused modules. In target mode (TARGET set) it also loads the
# VARS environment once per top-level command (see "Bootstrap" below) — this
# replaced infra.sh / lib/env.sh / lib/run.sh.
[[ "${INFRA_LIB_LOADED:-}" = true ]] && return 0
INFRA_LIB_LOADED=true

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# ---- always-on environment (exported so child processes in a chain see it) ----
# Pre-set values win (in-cluster pods ship INFRA_ROOT/PVC_BACKUP_DIR/MY_UID in
# their env and must not get host paths recomputed over them).
if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"
fi
export INFRA_ROOT
[ -n "${COMPOSE_STATE_DIR:-}" ] || export COMPOSE_STATE_DIR="$INFRA_ROOT/current_target/compose_live_state"
[ -n "${COMPOSE_STATE_BACKUP_DIR:-}" ] || export COMPOSE_STATE_BACKUP_DIR="$INFRA_ROOT/compose_state_backups"
[ -n "${K3S_STATE_DIR:-}" ] || export K3S_STATE_DIR="$INFRA_ROOT/current_target/k3s_live_state"
[ -n "${PVC_BACKUP_DIR:-}" ] || export PVC_BACKUP_DIR="$INFRA_ROOT/k3s_state_backups"
if [ -z "${INFRA_INTERACTIVE:-}" ]; then
    if [ -t 0 ]; then export INFRA_INTERACTIVE=true; else export INFRA_INTERACTIVE=false; fi
fi
export TARGET="${TARGET:-}"

# Retry a shell command string with configurable tries and delay
# args: tries delay command-string
retry() {
    local tries="${1:-30}"
    local delay="${2:-5}"
    shift 2
    for ((_=0; _<tries; _++)); do
        eval "$@" 2>/dev/null && return 0
        sleep "$delay"
    done
    return 1
}

_confirm() {
    local prompt="${1:-Proceed?}" yn
    read -r -p "$prompt [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]]
}

# Run docker, transparently retrying with sudo/run0 when the user lacks access
# to the docker socket (not in the docker group) — the user is prompted for
# elevation instead of the command failing. Only permission-denied errors
# trigger the retry; daemon-down and real CLI errors pass through unchanged.
docker() {
    local err_file rc
    err_file=$(mktemp)
    if command docker "$@" 2>"$err_file"; then
        rm -f "$err_file"
        return 0
    else
        rc=$?
        if grep -qi "permission denied" "$err_file"; then
            rm -f "$err_file"
            "$(get_sudo_cmd)" docker "$@"
            return $?
        fi
        cat "$err_file" >&2
        rm -f "$err_file"
        return "$rc"
    fi
}

source "$_lib_dir/pkg.sh"
source "$_lib_dir/net.sh"
source "$_lib_dir/k3s.sh"
source "$_lib_dir/compose.sh"
source "$_lib_dir/validate.sh"
source "$_lib_dir/pvc.sh"

# ---- Bootstrap (target mode) ------------------------------------------------
# Loads the VARS environment once per top-level command invocation. The guard
# is exported so child bash processes in a chain (group.sh -> deploy.sh ->
# component hooks) skip re-validation; every fresh `task <target>:<cmd>` run
# starts without it.

# Resolve the VARS file for $TARGET (order must match lib/vars_validator.py).
_resolve_vars_file() {
    local f
    for f in "$INFRA_ROOT/secrets/VARS.${TARGET:-}.env" "$INFRA_ROOT/secrets/VARS.env" \
             "$INFRA_ROOT/VARS.${TARGET:-}.env" "$INFRA_ROOT/VARS.env"; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# Command scripts whose render/apply steps hard-fail without VARS when a
# template exists (everything else loads VARS only when a file is present).
_vars_required() {
    case "$(basename "$0")" in
        install.sh|restart.sh|install-preboot.sh|deploy.sh|group.sh|update-node-ip.sh|backup-pvc.sh|restore-pvc.sh) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -n "$TARGET" ] && [ "${INFRA_ENV_LOADED:-}" != "1" ]; then
    export INFRA_ENV_LOADED=1

    if [ ! -d "$INFRA_ROOT/targets/$TARGET" ]; then
        echo "Error: unknown target '$TARGET'" >&2
        exit 1
    fi

    # Warn if this machine's hostname does not match the target name
    if [ "$(hostname)" != "$TARGET" ]; then
        echo "Warning: hostname '$(hostname)' does not match target '$TARGET'." >&2
        echo "Deploying may apply the wrong configuration. Press Enter to continue." >&2
        if [ "$INFRA_INTERACTIVE" = true ]; then
            read -r || true
        fi
    fi

    # Load VARS (compose generate-mtls-certs runs for other targets too — never loads).
    case "$(basename "$0")" in
        generate-mtls-certs.sh) ;;
        *)
            if _resolve_vars_file >/dev/null; then
                python3 "$INFRA_ROOT/lib/vars_validator.py" "$TARGET" || exit $?
                # shellcheck disable=SC1091
                source "$INFRA_ROOT/current_target/env.sh"
            elif _vars_required && [ -f "$INFRA_ROOT/targets/$TARGET/VARS.template.env" ]; then
                echo "Error: no VARS.$TARGET.env or VARS.env found. Create one from $INFRA_ROOT/targets/$TARGET/VARS.template.env" >&2
                exit 1
            fi
            ;;
    esac

    # Compose renders need DOCKER_GID and an envsubst allowlist even when no
    # VARS file exists (bigpc/pc/rpi use builtins only).
    case "$(basename "$0")" in
        install.sh|restart.sh|install-preboot.sh)
            if [ -z "${DOCKER_GID:-}" ]; then
                DOCKER_GID="$(getent group docker | cut -d: -f3)" || {
                    echo "Error: docker group not found. Is Docker installed?" >&2
                    exit 1
                }
                export DOCKER_GID
            fi
            if [ -z "${ENVSUBST_VARS:-}" ]; then
                # Builtin-only allowlist; mirror the list in lib/vars_validator.py.
                export ENVSUBST_VARS='$MY_UID $TARGET $COMPOSE_STATE_DIR $COMPOSE_STATE_BACKUP_DIR $K3S_STATE_DIR $PVC_BACKUP_DIR $INFRA_ROOT $DOCKER_GID $PROXY_IP $USER'
            fi
            ;;
    esac

    if [ -z "${MY_UID:-}" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            export MY_UID=1000
        else
            MY_UID="$(id -u)"
            export MY_UID
        fi
    fi
fi
