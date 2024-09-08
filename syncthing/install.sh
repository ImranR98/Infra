#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

docker pull syncthing/syncthing:latest
generateComposeService syncthing | awk -v SCRIPT_DIR="$HERE" '{gsub("path_to_here", SCRIPT_DIR); print}' | sudo tee /etc/systemd/system/syncthing.service.temp
awk -v MY_UID="$UID" '{gsub("User=1000", MY_UID); print}' /etc/systemd/system/syncthing.service.temp | sudo tee /etc/systemd/system/syncthing.service
sudo rm /etc/systemd/system/syncthing.service.temp
sudo systemctl enable syncthing.service
sudo systemctl restart syncthing.service