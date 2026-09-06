#!/bin/bash
# DESC: Install system prerequisites (task, Docker, yq, envsubst, jq, python3, go, python3-dotenv, shellcheck)
set -euo pipefail
# Direct-run bootstrap: machines without task yet can't run `task prereqs`, so
# compute INFRA_ROOT here when unset (task invocations always pass it inline).
if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/lib/common.sh"

SU=$(get_sudo_cmd)
PKG_MGR=$(detect_pkgmgr)

case "$PKG_MGR" in
    apt) $SU bash -c 'apt-get update -qq' ;;
    dnf) $SU bash -c 'dnf check-update -q' || true ;;
    rpm-ostree) rpm-ostree refresh-md ;;
esac

# Task CLI (dispatch layer). No distro package — pinned GitHub release binary.
install_task() {
    local ver="3.53.1" arch url tmp
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo "Error: unsupported architecture for the task binary" >&2; return 1 ;;
    esac
    url="https://github.com/go-task/task/releases/download/v${ver}/task_linux_${arch}.tar.gz"
    tmp="$(mktemp -d)"
    if curl -fsSL --connect-timeout 30 --max-time 120 "$url" | tar xz -C "$tmp" task 2>/dev/null; then
        $SU install -m 0755 "$tmp/task" /usr/local/bin/task
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

if ! command -v task >/dev/null 2>&1; then
    printf "Installing task..."
    if install_task; then echo " done"; else echo " failed"; ALL_OK=false; fi
else
    echo "task already installed."
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    printf "Installing Docker and Docker Compose..."
    case "$PKG_MGR" in
        rpm-ostree)
            # secureblue: no package manager, layer the official packages live
            rpm-ostree install --apply-live --assumeyes docker-ce docker-ce-cli containerd.io docker-compose-plugin && echo " done" || { echo ""; echo "Docker install failed. Install manually: https://docs.docker.com/engine/install/" >&2; }
            ;;
        *)
            # Official bootstrap (accepted unpinned fetch, like the dracut/etcdctl
            # downloads); needs curl, which the tool loop below also installs.
            install_pkgs "$SU" "$PKG_MGR" curl || true
            if $SU bash -c 'curl -fsSL --connect-timeout 30 --max-time 300 https://get.docker.com | sh'; then
                echo " done"
            else
                echo ""
                echo "Docker install failed. Install manually: https://docs.docker.com/engine/install/" >&2
            fi
            ;;
    esac
    $SU bash -c 'systemctl enable docker' 2>/dev/null || true
    $SU bash -c 'systemctl start docker' 2>/dev/null || true
else
    echo "Docker already installed."
fi

ALL_OK=true
for tool in yq envsubst jq curl python3 go openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf "Installing %s..." "$tool"
        case "$tool" in
            envsubst)
                case "$PKG_MGR" in
                    apt) pkg="gettext-base" ;;
                    dnf|rpm-ostree) pkg="gettext" ;;
                esac
                ;;
            python3)
                case "$PKG_MGR" in
                    apt) pkg="python3" ;;
                    dnf|rpm-ostree) pkg="python3" ;;
                esac
                ;;
            go)
                # For local Renovate runs (gomod manager); the in-cluster
                # renovate image ships its own Go toolchain.
                case "$PKG_MGR" in
                    apt) pkg="golang-go" ;;
                    dnf|rpm-ostree) pkg="golang" ;;
                esac
                ;;
            openssl) pkg="openssl" ;;
            *) pkg="$tool" ;;
        esac
        install_pkgs "$SU" "$PKG_MGR" "$pkg" && echo " done" || { echo " failed"; ALL_OK=false; }
    else
        echo "$tool already installed."
    fi
    if command -v "$tool" >/dev/null 2>&1; then
        echo "  [OK] $tool"
    else
        echo "  [MISSING] $tool"
        ALL_OK=false
    fi
done

# python3-dotenv is a runtime dependency of lib/vars_validator.py (VARS parsing).
if ! python3 -c 'import dotenv' >/dev/null 2>&1; then
    printf "Installing python3-dotenv..."
    if install_pkgs "$SU" "$PKG_MGR" python3-dotenv; then echo " done"; else echo " failed"; ALL_OK=false; fi
else
    echo "python3-dotenv already installed."
fi
if python3 -c 'import dotenv' >/dev/null 2>&1; then
    echo "  [OK] python3-dotenv"
else
    echo "  [MISSING] python3-dotenv"
    ALL_OK=false
fi

# Dev-only (task lint): shellcheck.
if ! command -v shellcheck >/dev/null 2>&1; then
    printf "Installing shellcheck (dev)..."
    install_pkgs "$SU" "$PKG_MGR" shellcheck && echo " done" || { echo " failed"; ALL_OK=false; }
else
    echo "shellcheck already installed."
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "  [OK] docker"
    echo "  [OK] docker compose"
else
    echo "  [MISSING] docker or docker compose"
    ALL_OK=false
fi

if [ "$ALL_OK" = true ]; then
    echo ""
    echo "All prerequisites installed."
else
    echo ""
    echo "Some prerequisites are missing. Install them manually." >&2
    exit 1
fi
