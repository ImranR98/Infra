#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
docker pull imranrdev/logtfy
docker run --rm imranrdev/logtfy k8s >"$HERE"/prepLogtfy.sh
docker run --rm imranrdev/logtfy role >"$HERE"/role.yaml
bash "$HERE"/prepLogtfy.sh production
echo "KUBE_API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" >"$HERE"/.env
awk -v SCRIPT_DIR="$HERE" '{gsub("path_to_here", SCRIPT_DIR); print}' "$HERE"/docker-compose.service | sudo tee /etc/systemd/system/docker-compose.service.temp
awk -v MY_UID="$UID" '{gsub("User=1000", MY_UID); print}' /etc/systemd/system/docker-compose.service.temp | sudo tee /etc/systemd/system/docker-compose.service
sudo rm /etc/systemd/system/docker-compose.service.temp
sudo systemctl enable --now docker-compose.service
