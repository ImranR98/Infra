#!/bin/bash
set -euo pipefail

echo "=== Radarr Manual Setup ==="
echo ""
echo "1. Access https://radarr.${SERVICES_DOMAIN} (authenticate via Authelia)"
echo "2. Settings > General > Authentication: Forms, create admin account"
echo "3. Settings > Media Management > Root Folders: /data/Movies"
echo "4. Settings > Download Clients > Add (qBittorrent):"
echo "     Host: qbittorrent.apps.svc.cluster.local  Port: 8080"
echo "     Username/Password: from qBittorrent setup"
echo "5. Settings > Indexers: add via Prowlarr, or add manually"
echo "6. Settings > Connect > Add (Emby / Jellyfin):"
echo "     Host: http://jellyfin.apps.svc.cluster.local:8096"
echo "     API Key: from Jellyfin Dashboard > API Keys"
echo "     Notifications: On Import, On Upgrade"
echo ""
echo "API Key (pre-configured): see kubectl -n apps get secret radarr-secret"
