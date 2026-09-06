#!/bin/bash
# lib/pkg.sh — package management

get_sudo_cmd() {
    echo "sudo"
}

detect_pkgmgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    else echo "unknown"
    fi
}

install_pkgs() {
    local su="$1"; local pkgmgr="$2"; shift 2
    local cmd_str
    printf -v cmd_str '%q ' "$@"
    case "$pkgmgr" in
        apt) "$su" bash -c "apt-get install -y $cmd_str" || return 1 ;;
        dnf) "$su" bash -c "dnf install -y $cmd_str" || return 1 ;;
        *) return 1 ;;
    esac
}
