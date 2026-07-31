#!/bin/bash
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

echo "Waiting for qBittorrent to be ready..."
kubectl -n apps wait --for=condition=ready pod -l app=qbittorrent --timeout=120s

echo "qBittorrent temporary password:"
kubectl -n apps logs deploy/qbittorrent 2>&1 | grep -o 'A temporary password is provided for this session: \S*'
