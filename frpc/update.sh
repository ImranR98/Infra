#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LATEST_TAG="$(curl -s https://hub.docker.com/v2/repositories/fatedier/frpc/tags | grep -Eo 'name":"v[^"]+' | awk -F '"' '{print $NF}' | head -1)"
CURRENT_TAG="$(docker images | grep 'fatedier/frpc' | head -1 | awk '{print $2}')"
if [ "$CURRENT_TAG" != "$LATEST_TAG" ]; then
    docker pull fatedier/frpc:"$LATEST_TAG"
    sed -i "s/$CURRENT_TAG/$LATEST_TAG/g" "$HERE"/frpc.docker-compose.yaml
    sudo systemctl restart frpc.service
fi