#!/bin/bash
set -e

HERE_F00D="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE_F00D"/prep_env.sh

cat "$HERE_F00D"/landscape.docker-compose.yaml | envsubst >"$STATE_DIR"/landscape.docker-compose.yaml

if [ -n "$1" ]; then
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml down "$1" || :
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml up -d "$1" --remove-orphans
else
    echo "No service specified. Nothing will be restarted."
fi
