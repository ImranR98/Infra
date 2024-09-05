#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
awk -v SCRIPT_DIR="$HERE" '{gsub("path_to_here", SCRIPT_DIR); print}' "$HERE"/frpc.service | sudo tee /etc/systemd/system/frpc.service
sudo systemctl enable --now frpc.service
