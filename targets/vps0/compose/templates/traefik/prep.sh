#!/bin/bash
# traefik-specific compose prep: seed acme.json for Let's Encrypt certificate storage
set -euo pipefail

COMPOSE_STATE_DIR="${INFRA_ROOT:?}/current_target/compose_live_state"
mkdir -p "$COMPOSE_STATE_DIR/traefik"

if [ ! -f "$COMPOSE_STATE_DIR/traefik/acme.json" ]; then
    echo '{}' > "$COMPOSE_STATE_DIR/traefik/acme.json"
    chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"
fi

mkdir -p "$COMPOSE_STATE_DIR/traefik/plugins-local/src/github.com/imranr/authelia-header-gate"
cp "$INFRA_ROOT/lib/plugins/authelia-header-gate/plugin.wasm" \
   "$INFRA_ROOT/lib/plugins/authelia-header-gate/.traefik.yml" \
   "$COMPOSE_STATE_DIR/traefik/plugins-local/src/github.com/imranr/authelia-header-gate/"
