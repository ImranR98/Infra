#!/bin/bash
# traefik-specific compose prep: seed acme.json for Let's Encrypt certificate storage
set -euo pipefail

COMPOSE_STATE_DIR="${ATLAS_ROOT:?}/current_target/compose_live_state"
mkdir -p "$COMPOSE_STATE_DIR/traefik"

if [ ! -f "$COMPOSE_STATE_DIR/traefik/acme.json" ]; then
    echo '{}' > "$COMPOSE_STATE_DIR/traefik/acme.json"
    chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"
fi
