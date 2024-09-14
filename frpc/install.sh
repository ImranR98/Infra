#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

# Update image tag
LATEST_TAG="$(curl -s https://hub.docker.com/v2/repositories/fatedier/frpc/tags | grep -Eo 'name":"v[^"]+' | awk -F '"' '{print $NF}' | head -1)"
CURRENT_TAG="$(docker images | grep 'fatedier/frpc' | head -1 | awk '{print $2}')"
if [ "$CURRENT_TAG" != "$LATEST_TAG" ]; then
    docker pull fatedier/frpc:"$LATEST_TAG"
    sed -i "s/$CURRENT_TAG/$LATEST_TAG/g" "$HERE"/frpc.docker-compose.yaml
fi

# Generate/update config
bash "$HERE"/files/generate_config.sh

# Install service
generateComposeService frpc | awk -v SCRIPT_DIR="$HERE" '{gsub("path_to_here", SCRIPT_DIR); print}' | sudo tee /etc/systemd/system/frpc.service
sudo systemctl enable frpc.service
sudo systemctl stop frpc.service || :
sleep 5
sudo systemctl start frpc.service