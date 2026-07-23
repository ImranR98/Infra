#!/bin/bash
# lib/pkg.sh — package management

get_sudo_cmd() {
    local has_sudo=false has_run0=false
    command -v sudo  >/dev/null 2>&1 && has_sudo=true
    command -v run0  >/dev/null 2>&1 && has_run0=true

    if $has_run0 && $has_sudo; then
        ${ATLAS_INTERACTIVE:-false} && echo "sudo" || echo "run0"
    elif $has_run0; then
        echo "run0"
    else
        echo "sudo"
    fi
}

detect_pkgmgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v rpm-ostree >/dev/null 2>&1; then echo "rpm-ostree"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    else echo "unknown"
    fi
}

install_pkgs() {
    local su="$1"; local pkgmgr="$2"; shift 2
    local cmd_str
    printf -v cmd_str '%q ' "$@"
    case "$pkgmgr" in
        apt) $su bash -c "apt-get install -y $cmd_str" || return 1 ;;
        dnf) $su bash -c "dnf install -y $cmd_str" || return 1 ;;
        rpm-ostree) rpm-ostree install --apply-live --assumeyes $cmd_str || return 1 ;;
        *) return 1 ;;
    esac
}

ensure_docker_repo() {
    local su="$1"; local pkgmgr="$2"
    case "$pkgmgr" in
        apt)
            install_pkgs "$su" "$pkgmgr" curl gnupg
            $su bash -c 'install -m 0755 -d /etc/apt/keyrings'
            os_id=$(. /etc/os-release && echo "${ID:-ubuntu}")
            os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
            case "$os_id" in
                debian) docker_distro="debian" ;;
                *)      docker_distro="ubuntu" ;;
            esac
            curl -fsSL "https://download.docker.com/linux/$docker_distro/gpg" | $su bash -c 'gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_distro $os_codename stable" | $su bash -c 'tee /etc/apt/sources.list.d/docker.list >/dev/null'
            $su bash -c "$pkgmgr update -qq"
            ;;
        dnf)
            $su bash -c "$pkgmgr install -y dnf-plugins-core"
            $su bash -c "$pkgmgr config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo"
            ;;
        rpm-ostree)
            rpm-ostree refresh-md
            ;;
    esac
}
