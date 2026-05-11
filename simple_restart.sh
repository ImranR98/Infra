#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/prep_env.sh

envsubst < "$HERE"/compose.yaml > "$STATE_DIR"/compose.yaml

if [ -n "${1:-}" ]; then
    docker compose -p luna -f "$STATE_DIR"/compose.yaml down "$1" || :
    docker compose -p luna -f "$STATE_DIR"/compose.yaml up -d "$1"
else
    echo "No service specified. Nothing will be restarted."
fi
