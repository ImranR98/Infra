#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if [ -n "$1" ]; then
    docker compose -p landscape-remote -f "$HERE"/state/landscape-remote.docker-compose.yaml down "$1"
    docker compose -p landscape-remote -f "$HERE"/state/landscape-remote.docker-compose.yaml up -d "$1"
    exit
fi

awk -v SCRIPT_DIR="$HERE/state" '{gsub("path_to_here", SCRIPT_DIR); print}' "$HERE"/state/landscape-remote.service | sudo tee /etc/systemd/system/landscape-remote.service.temp
awk -v MY_UID="$UID" '{gsub("User=1000", MY_UID); print}' /etc/systemd/system/landscape-remote.service.temp | sudo tee /etc/systemd/system/landscape-remote.service
sudo rm /etc/systemd/system/landscape-remote.service.temp
sudo systemctl daemon-reload
sudo systemctl enable landscape-remote.service
sudo systemctl stop landscape-remote.service || :
sleep 5
sudo systemctl start landscape-remote.service