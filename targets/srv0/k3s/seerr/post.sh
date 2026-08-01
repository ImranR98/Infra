#!/bin/bash
set -euo pipefail

echo "=== Seerr Manual Setup ==="
echo ""
echo "1. Access https://seerr.${SERVICES_DOMAIN:-home.example.org} (authenticate via Authelia)"
echo "2. Sign in with your Jellyfin account:"
echo "     Host: http://jellyfin.apps.svc.cluster.local:8096"
echo "3. Settings > Services > Add Jellyfin:"
echo "     Host: http://jellyfin.apps.svc.cluster.local:8096"
echo "     API Key: from Jellyfin Dashboard > API Keys"
echo "4. Settings > Services > Add Radarr:"
echo "     URL: http://radarr.apps.svc.cluster.local:7878"
echo "     API Key: from kubectl -n apps get secret radarr-secret"
echo "5. Settings > Services > Add Sonarr:"
echo "     URL: http://sonarr.apps.svc.cluster.local:8989"
echo "     API Key: from kubectl -n apps get secret sonarr-secret"
echo ""
