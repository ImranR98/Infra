#!/bin/bash
set -e

HERE_F00D="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE_F00D"/prep_env.sh
PROJECT='landscape'
if [ -n "$2" ]; then
    PROJECT="$2"
fi
cat "$HERE_F00D"/"$PROJECT".docker-compose.yaml | envsubst >"$STATE_DIR"/"$PROJECT".docker-compose.yaml
if [ -n "$1" ]; then
    docker compose -p "$PROJECT" -f ./state/"$PROJECT".docker-compose.yaml down "$1"
    docker compose -p "$PROJECT" -f ./state/"$PROJECT".docker-compose.yaml up -d "$1"
else
    echo "No service specified. Nothing will be restarted."
fi
