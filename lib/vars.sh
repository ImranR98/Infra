#!/bin/bash

_vars_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
VARS_ROOT="${VARS_ROOT:-"$(cd "$_vars_lib_dir/.." >/dev/null 2>&1 && pwd)"}"

source_env() {
    local target="${TARGET:-${1:-}}"
    if [ -z "$target" ]; then
        echo "Error: TARGET must be set before calling source_env" >&2
        exit 1
    fi

    local vars_file="$VARS_ROOT/VARS.sh"
    if [ ! -f "$vars_file" ]; then
        echo "Error: VARS.sh not found at $vars_file" >&2
        exit 1
    fi

    while IFS= read -r var; do
        if ! grep -q "^export $var=" "$vars_file"; then
            echo "Error: VARS.sh is missing required variable: $var" >&2
            exit 1
        fi
    done < <(grep -hEo '^export [^=]+' "$VARS_ROOT/vars/VARS.common.sh" "$VARS_ROOT/vars/VARS.${target}.sh" 2>/dev/null | sed 's/^export //' | sort -u)

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
    if [ -f "$VARS_ROOT/VARS.sh" ]; then
        vars=$(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$VARS_ROOT/VARS.sh" | sed 's/^/$/' | tr '\n' ' ')
    fi
    for v in MY_UID TARGET; do
        vars="$vars \$$v"
    done
    echo "$vars"
}
