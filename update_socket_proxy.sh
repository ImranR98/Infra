#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/prep_env.sh

printTitle "Pull Latest 'wollomatic/socket-proxy:1' and Restart Luna if Needed"

OLDSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"
docker pull wollomatic/socket-proxy:1
NEWSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"

if [ "$OLDSPHASH" != "$NEWSPHASH" ]; then
    read -p "New image pulled. Press enter to restart luna..." NOTHING
    systemctl restart luna
else
    echo "Note that this script will only detect updates if the tag \"wollomatic/socket-proxy:1\" (major version 1) has not changed."
fi
