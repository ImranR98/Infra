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

# Update strelaysrv
git -C strelaysrv-docker pull || git clone git@github.com:ImranR98/strelaysrv-docker.git
cd strelaysrv-docker
./build.sh
cd ..

# Install service
awk -v SCRIPT_DIR="$HERE" '{gsub("path_to_here", SCRIPT_DIR); print}' "$HERE"/strelaysrv.service | sudo tee /etc/systemd/system/strelaysrv.service.temp
awk -v MY_UID="$UID" '{gsub("User=1000", MY_UID); print}' /etc/systemd/system/strelaysrv.service.temp | sudo tee /etc/systemd/system/strelaysrv.service
sudo rm /etc/systemd/system/strelaysrv.service.temp
sudo systemctl daemon-reload
sudo systemctl enable strelaysrv.service
sudo systemctl stop strelaysrv.service || :
sleep 5
sudo systemctl start strelaysrv.service
echo "strelaysrv installed. You may still need to open ports manually (run openTCPPorts.sh with a port number argument)."