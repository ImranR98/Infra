#!/bin/bash
set -e

read -p "WARNING: ONLY run this script if you have LOCAL access to the FRPC machine. Type 'continue' to continue. " USER_RESPONSE
if [ "$USER_RESPONSE" != 'continue' ]; then
    exit
fi

HERE_2G4U="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE_2G4U"/prep_env.sh

MYFRPVER="$(cat "$HERE_2G4U"/frpc.docker-compose.yaml | grep -Eo 'fatedier/frpc:.+' | awk -F: '{print $NF}')"
THEIRFRPVER="$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep -oE 'tag/.*' | tail -c +5 | head -c -3)"

if [ "$MYFRPVER" != "$THEIRFRPVER" ]; then
    printTitle "Update Docker Compose File for FRPC ($MYFRPVER to $THEIRFRPVER) and Restart the Service"
    sed -i "s/fatedier\/frpc:$MYFRPVER/fatedier\/frpc:$THEIRFRPVER/g" "$HERE_2G4U"/frpc.docker-compose.yaml
    cat "$HERE_2G4U"/frpc.docker-compose.yaml | envsubst >"$STATE_DIR"/frpc.docker-compose.yaml
    bash "$HERE_2G4U"/simple_restart.sh frpc frpc

    printTitle "Rebuild FRPS Image and Restart the Service"
    scp "$HERE_2G4U"/files/frps.create-image.sh "$PROXY_SSH_STRING":~/landscape-remote-services/frps.create-image.sh
    ssh -A -t "$PROXY_SSH_STRING" "bash '$PROXY_HOME/landscape-remote-services/frps.create-image.sh'"
    scp "$HERE_2G4U"/files/landscape-remote.install.sh "$PROXY_SSH_STRING":~/landscape-remote-services/landscape-remote.install.sh
    ssh -A -t "$PROXY_SSH_STRING" "bash '$PROXY_HOME/landscape-remote-services/landscape-remote.install.sh' frps-with-multiuser"
fi
