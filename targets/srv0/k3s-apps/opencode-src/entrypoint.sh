#!/usr/bin/env bash
# Seed the PVC-backed toolchains (Homebrew + nvm/Node) from the image on first
# start, then hand off to the requested command. Runs as the unprivileged
# opencode user; the init container only chowns the two volumes.
set -euo pipefail

export HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
export HOMEBREW_CELLAR="$HOMEBREW_PREFIX/Cellar"
export HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX/Homebrew"
export HOMEBREW_CACHE="${HOMEBREW_CACHE:-/home/linuxbrew/.cache/Homebrew}"
export HOMEBREW_NO_ANALYTICS=1
export NVM_DIR="${NVM_DIR:-/home/linuxbrew/.nvm}"

mkdir -p "$HOME/.cache" "$HOME/.local/bin" "$HOME/.config" "$HOME/.ssh" "$HOME/.gnupg"
chmod 700 "$HOME/.ssh" "$HOME/.gnupg"
mkdir -p /home/linuxbrew/.cache

# seed_tree <seed-dir> <target-dir> <sentinel>
# Copy a baked toolchain into the PVC only when the target is absent/broken.
seed_tree() {
    local seed="$1"
    local target="$2"
    local sentinel="$3"
    local tmp

    if [ -e "$target/$sentinel" ]; then
        return 0
    fi
    if [ ! -d "$seed" ]; then
        echo "Warning: seed $seed is missing; $target will be unavailable" >&2
        return 0
    fi

    echo "Seeding $target from $seed (first start)..." >&2
    tmp="${target}.seed.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    cp -a "$seed/." "$tmp/"
    touch "$tmp/.seeded"
    rm -rf "$target"
    mv "$tmp" "$target"
}

seed_tree /opt/homebrew-seed "$HOMEBREW_PREFIX" bin/brew
seed_tree /opt/nvm-seed "$NVM_DIR" nvm.sh

if [ -x "$HOMEBREW_PREFIX/bin/brew" ]; then
    eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
fi

if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    if [ -n "${NODE_VERSION:-}" ] && [ ! -x "$NVM_DIR/versions/node/v${NODE_VERSION}/bin/node" ]; then
        echo "Installing Node ${NODE_VERSION} with nvm..." >&2
        if ! nvm install "$NODE_VERSION"; then
            echo "Warning: nvm install failed; Node may be unavailable" >&2
        fi
    fi
    if [ ! -s "$NVM_DIR/alias/default" ] && [ -n "${NODE_VERSION:-}" ]; then
        nvm alias default "$NODE_VERSION" >/dev/null 2>&1 || true
    fi
    nvm use --silent default >/dev/null 2>&1 || true
fi

exec "$@"
