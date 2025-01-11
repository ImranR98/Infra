#!/bin/bash
set -e

HERE_LX1A="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE_LX1A"/prep_env.sh
cat "$HERE_LX1A"/landscape.docker-compose.yaml | envsubst >"$STATE_DIR"/landscape.docker-compose.yaml
if [ -n "$1" ]; then
    docker compose -p landscape -f ./state/landscape.docker-compose.yaml down "$1"
    docker compose -p landscape -f ./state/landscape.docker-compose.yaml up -d "$1"
else
    echo "No service specified. Nothing will be restarted."
fi
