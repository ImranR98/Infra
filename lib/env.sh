#!/bin/bash
# lib/env.sh — environment, VARS file loading, envsubst

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

    # Auto-hash any variable ending in _HASHABLE → _HASHED
    while IFS='=' read -r var value; do
        case "$var" in *_HASHABLE)
            hashed_var="${var%_HASHABLE}_HASHED"
            printf -v "$hashed_var" '%s' "$(printf '%s' "$value" | openssl passwd -6 -stdin)"
            export "$hashed_var"
            ;;
        esac
    done < <(env | grep '^[A-Z_][A-Z_0-9]*_HASHABLE=')

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

    for v in MY_UID TARGET COMPOSE_STATE_DIR COMPOSE_STATE_BACKUP_DIR K3S_STATE_DIR PVC_BACKUP_DIR DOCKER_GID PROXY_IP; do
        case " $vars " in *" $v "*) ;; *) vars="$vars $v" ;; esac
    done

    for v in $(env | grep -o '^[A-Z_][A-Z_0-9]*_HASHED=' | sed 's/=//'); do
        case " $vars " in *" $v "*) ;; *) vars="$vars $v" ;; esac
    done

    echo "$vars" | tr ' ' '\n' | sort -u | sed 's/^/$/' | tr '\n' ' '
}

ensure_envsubst_vars() { export ENVSUBST_VARS="${ENVSUBST_VARS:-$(get_envsubst_vars)}"; }
