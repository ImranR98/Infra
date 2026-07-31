#!/bin/bash
set -euo pipefail

echo "=== Radarr Manual Setup ==="
echo ""
echo "1. Access https://radarr.${SERVICES_DOMAIN:-home.example.org} (authenticate via Authelia)"
echo "2. Settings > General > Authentication: Forms, create admin account"
echo "3. Settings > Media Management > Root Folders: /data/Movies"
echo "4. Settings > Download Clients > Add (qBittorrent):"
echo "     Host: qbittorrent.apps.svc.cluster.local  Port: 8080"
echo "     Username/Password: from qBittorrent setup"
echo "5. Settings > Indexers: add via Prowlarr, or add manually"
echo ""
echo "API Key (pre-configured): see kubectl -n apps get secret radarr-secret"
