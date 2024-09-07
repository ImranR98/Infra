#!/bin/bash
set -e

# Prep
ORIGINAL_DIR="$(pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
UPDATE_DIR=/update_artifacts
sudo mkdir -p "$UPDATE_DIR"
sudo chown $(id -u):$(id -g) "$UPDATE_DIR"
trap "cd '$ORIGINAL_DIR'" EXIT
cd "$UPDATE_DIR"

# Update FRPS
git -C frps-with-multiuser-docker pull || git clone git@github.com:ImranR98/frps-with-multiuser-docker.git
cd frps-with-multiuser-docker
./build.sh
cd ..

# Install service
awk -v SCRIPT_DIR="$HERE" '{gsub("path_to_here", SCRIPT_DIR); print}' "$HERE"/frps.service | sudo tee /etc/systemd/system/frps.service
sudo systemctl daemon-reload
sudo systemctl enable frps.service
sudo systemctl restart frps.service