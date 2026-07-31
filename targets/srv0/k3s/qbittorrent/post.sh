#!/bin/bash
set -euo pipefail

echo "Waiting for qBittorrent to be ready..."
retry 60 5 "kubectl -n apps get pod -l app=qbittorrent -o jsonpath='{.items[0].status.containerStatuses[0].ready}' | grep -q true"

echo "qBittorrent temporary password:"
kubectl -n apps logs deploy/qbittorrent 2>&1 | grep -o 'A temporary password is provided for this session: \S*'
