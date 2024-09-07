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

# Update logtfy
docker pull imranrdev/logtfy

# Install service
awk -v SCRIPT_DIR="$HERE" '{gsub("path_to_here", SCRIPT_DIR); print}' "$HERE"/logtfy.service | sudo tee /etc/systemd/system/logtfy.service.temp
awk -v MY_UID="$UID" '{gsub("User=1000", MY_UID); print}' /etc/systemd/system/logtfy.service.temp | sudo tee /etc/systemd/system/logtfy.service
sudo rm /etc/systemd/system/logtfy.service.temp
sudo systemctl daemon-reload
sudo systemctl enable logtfy.service
sudo systemctl stop logtfy.service || :
sleep 5
sudo systemctl start logtfy.service