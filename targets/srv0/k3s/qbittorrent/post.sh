#!/bin/bash
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"

echo "=== qBittorrent Manual Setup ==="
echo ""
echo "Waiting for qBittorrent to be ready..."
kubectl -n apps wait --for=condition=ready pod -l app=qbittorrent --timeout=120s

echo "qBittorrent temporary password:"
kubectl -n apps logs deploy/qbittorrent 2>&1 | grep -o 'A temporary password is provided for this session: \S*'

echo ""
echo "1. Access https://qbittorrent.${SERVICES_DOMAIN:-home.example.org} (authenticate via Authelia)"
echo "2. Log in with the temporary password above"
echo "3. Tools > Options > Web UI > Authentication: set a permanent password"
echo "4. Tools > Options > Downloads > Default Save Path: /data/downloads"
echo "5. (Optional) Tools > Options > Downloads > Categories:"
echo "     radarr  /data/downloads/radarr"
echo "     sonarr  /data/downloads/sonarr"
