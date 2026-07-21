#!/bin/bash
set -euo pipefail

_desc() {
    local f="$1"
    local d; d=$(sed -n '2{s/^# DESC: //p;q}' "$f" 2>/dev/null)
    if [ -n "$d" ]; then echo "  $d"; fi
}

atlas_dispatch() {
    local cmd_args=("$@")

    case "${cmd_args[0]:-}" in
        validate)  validate "$TARGET"; exit $? ;;
        list-domains) list_domains "$TARGET"; exit $? ;;
    esac

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
    echo "  validate            Check configs for errors"
    echo "  list-domains        Show domains used by this target"
    for f in commands/*.sh; do
        [ -f "$f" ] || continue
        printf '  %-19s' "$(basename "${f%.*}")"
        _desc "$f"
    done
    for f in "targets/$TARGET"/commands/*.sh; do
        [ -f "$f" ] || continue
        printf '  %-19s' "$(basename "${f%.*}")"
        _desc "$f"
    done
    for stack in compose k3s; do
        [ -d "targets/$TARGET/$stack" ] || continue
        local has_cmds=false
        for f in "commands/$stack"/*.sh; do
            [ -f "$f" ] || continue
            [ "$has_cmds" = false ] && echo "" && has_cmds=true
            printf '  %s %-15s' "$stack" "$(basename "${f%.*}")"
            _desc "$f"
        done
        for f in "targets/$TARGET"/commands/"$stack"/*.sh; do
            [ -f "$f" ] || continue
            [ "$has_cmds" = false ] && echo "" && has_cmds=true
            printf '  %s %-15s' "$stack" "$(basename "${f%.*}")"
            _desc "$f"
        done
    done
    if $_err; then exit 1; fi
    exit 0
}
