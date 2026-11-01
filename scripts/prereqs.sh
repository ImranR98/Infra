#!/bin/bash
# DESC: Install system prerequisites on THIS machine: packages (incl. the
# NFS client dependencies), the pinned helm binary, Docker (official
# bootstrap), and the machine-fact .env + host bind dirs for the local compose
# target (hostname == target). Node/npm come from the distro only when no
# working Node and no version manager (fnm/nvm/volta/asdf/mise) is already
# present. Idempotent — re-run after repo changes that add compose bind dirs.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"
set_my_uid

SU="sudo"
HELM_VERSION="3.22.1"

usage() {
    echo "Usage: $(basename "$0")"
    echo
    echo "Machine-local (no target): installs packages (incl. the NFS"
    echo "client deps), helm, Docker, then prepares the compose state for this"
    echo "machine's target (hostname-matched): machine-fact .env, host bind dirs"
    echo "owned by \$MY_UID, and the traefik acme.json seed."
    exit 1
}

[ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; } && usage

# Node only backs the manual Renovate run (scripts/renovate.sh) and the
# explorer dev server, so prefer whatever is already there: installing the
# distro packages on top of a version manager (or an existing Node) shadows it
# and breaks the manager's per-shell versions.
install_node=true
node_manager=""
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    install_node=false
    echo "==> Using existing Node at $(command -v node)"
else
    for candidate in "${FNM_DIR:-$HOME/.local/share/fnm}" "$HOME/.fnm" \
        "${NVM_DIR:-$HOME/.nvm}" "$HOME/.volta" "$HOME/.asdf" \
        "$HOME/.local/share/mise"; do
        if [ -d "$candidate" ]; then
            node_manager="$candidate"
            break
        fi
    done
    if [ -n "$node_manager" ]; then
        install_node=false
        echo "==> Found Node version manager at $node_manager — not installing distro nodejs/npm"
        echo "    Activate it to use Node (e.g. fnm env --use-on-cd, or nvm use)."
    fi
fi

if command -v dnf >/dev/null 2>&1; then
    PKG_CMD=(dnf install -y)
    PACKAGES=(yq jq curl python3 openssl shellcheck yamllint git acl nfs-utils wireguard-tools)
elif command -v apt-get >/dev/null 2>&1; then
    $SU apt-get update -y
    PKG_CMD=(apt-get install -y)
    PACKAGES=(yq jq curl python3 openssl shellcheck yamllint git acl nfs-common wireguard-tools)
else
    echo "Error: neither dnf nor apt-get found — cannot install packages" >&2
    exit 1
fi
[ "$install_node" = true ] && PACKAGES+=(nodejs npm)

echo "==> Installing packages"
$SU "${PKG_CMD[@]}" "${PACKAGES[@]}"

if [ ! -x /usr/local/bin/helm ]; then
    echo "==> Installing helm v$HELM_VERSION"
    case "$(uname -m)" in
        aarch64) arch=arm64 ;;
        *) arch=amd64 ;;
    esac
    helm_tgz="helm-v${HELM_VERSION}-linux-${arch}.tar.gz"
    curl -fsSL "https://get.helm.sh/${helm_tgz}" -o /tmp/helm.tar.gz
    expected=$(curl -fsSL "https://get.helm.sh/${helm_tgz}.sha256sum" | awk '{print $1}')
    actual=$(sha256sum /tmp/helm.tar.gz | awk '{print $1}')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "Error: helm tarball checksum verification failed" >&2
        rm -f /tmp/helm.tar.gz
        exit 1
    fi
    tar -xzf /tmp/helm.tar.gz -C /tmp
    $SU install -m 0755 "/tmp/linux-${arch}/helm" /usr/local/bin/helm
    rm -rf /tmp/helm.tar.gz "/tmp/linux-${arch}"
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "==> Installing Docker (official bootstrap)"
    curl -fsSL --connect-timeout 30 --max-time 300 https://get.docker.com -o /tmp/get-docker.sh
    $SU sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi
$SU systemctl enable --now docker

# ---- Local compose target prep (hostname-matched target only) ---------------
local_target="$(hostname)"
target_dir="$INFRA_ROOT/targets/$local_target"

if [ -d "$target_dir/compose" ] && [ -f "$target_dir/compose/compose.yaml" ]; then
    compose_files=(-f "$target_dir/compose/compose.yaml")
    [ -f "$target_dir/compose/compose.private.yaml" ] && compose_files+=(-f "$target_dir/compose/compose.private.yaml")

    env_args=()
    ensure_machine_env "$local_target"
    echo "==> Wrote machine-fact env: $target_dir/compose/.env"
    # The private overlay can carry secrets; keep it owner-only.
    if [ -f "$target_dir/compose/compose.private.yaml" ]; then
        $SU chmod 600 "$target_dir/compose/compose.private.yaml"
    fi
    env_args+=(--env-file "$target_dir/compose/.env")
    # VARS-driven targets take the shared config env too (later file wins —
    # facts would override any collision, which is the point).
    [ -f "$INFRA_ROOT/config/$local_target/compose.env" ] && env_args=(--env-file "$INFRA_ROOT/config/$local_target/compose.env" "${env_args[@]}")

    profile_args=()
    profiles="$(config_env "$local_target" COMPOSE_PROFILES || true)"
    if [ -n "$profiles" ]; then
        IFS=', ' read -r -a profile_list <<<"$profiles"
        for profile in "${profile_list[@]}"; do
            [ -n "$profile" ] && profile_args+=(--profile "$profile")
        done
    fi

    echo "==> Resolving compose host bind dirs"
    # Host bind dirs come from `docker compose config` itself (the interpolated,
    # resolved output) — the compose file is the single source of truth. Docker
    # would create missing dirs as root; creating them here keeps them writable
    # by containers running as $MY_UID.
    bind_dirs=$(
        docker compose -p "$local_target" "${compose_files[@]}" "${env_args[@]}" "${profile_args[@]}" \
            config --format yaml 2>/dev/null |
            yq -r '.services[] | select(.volumes) | .volumes[] | (.source? // .) | split(":") | .[0]' |
            grep -F "$COMPOSE_STATE_DIR/" || true
    )
    sort -u <<<"$bind_dirs" | while read -r d; do
        [ -n "$d" ] || continue
        # A dot in the final path component means a file bind — create its parent.
        [[ "${d##*/}" == *.* ]] && d="${d%/*}"
        $SU mkdir -p "$d"
        $SU chown "${MY_UID}:${MY_UID}" "$d"
    done

    # Secret files the compose stack mounts from config/ must be readable by
    # containers running as $MY_UID (they are 0600 on the host).
    sed -n 's/^[[:space:]]*-[[:space:]]*\(\.\.\/\.\.\/\.\.\/config\/[A-Za-z0-9_.\/-]*\).*/\1/p' "$target_dir/compose/compose.yaml" |
        while read -r src; do
            [ -n "$src" ] || continue
            [ -f "$target_dir/compose/$src" ] && $SU chown "${MY_UID}:${MY_UID}" "$target_dir/compose/$src"
        done

    if grep -q 'traefik/acme' "$target_dir/compose/compose.yaml"; then
        acme_dir="$COMPOSE_STATE_DIR/traefik"
        $SU mkdir -p "$acme_dir"
        if [ ! -f "$acme_dir/acme.json" ]; then
            $SU bash -c "printf '{}' > '$acme_dir/acme.json'"
            $SU chown "${MY_UID}:${MY_UID}" "$acme_dir/acme.json"
            $SU chmod 600 "$acme_dir/acme.json"
            echo "==> Seeded $acme_dir/acme.json"
        fi
    fi
fi

echo "==> Verifying prerequisites"
missing=0
for tool in helm docker yq jq curl python3 openssl shellcheck yamllint node npm npx; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "  [OK] $tool"
        continue
    fi
    case "$tool" in
        node | npm | npx)
            # A detected version manager owns Node; it is just not initialized
            # in this non-interactive shell, so this is not a failed prereq.
            if [ -n "$node_manager" ]; then
                echo "  [SKIP] $tool (version manager at $node_manager is not initialized)"
                continue
            fi
            ;;
    esac
    echo "  [MISSING] $tool"
    missing=1
done
if docker compose version >/dev/null 2>&1; then
    echo "  [OK] docker compose"
else
    echo "  [MISSING] docker compose"
    missing=1
fi
exit $missing
