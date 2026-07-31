#!/bin/bash
set -euo pipefail

echo "=== Prowlarr Manual Setup ==="
echo ""
echo "1. Access https://prowlarr.${SERVICES_DOMAIN:-home.example.org} (authenticate via Authelia)"
echo "2. Settings > General > Authentication: Forms, create admin account"
echo "3. Settings > Apps > Add Radarr:"
echo "     URL: http://radarr.apps.svc.cluster.local:7878"
echo "     API Key: from kubectl -n apps get secret radarr-secret"
echo "4. Settings > Apps > Add Sonarr:"
echo "     URL: http://sonarr.apps.svc.cluster.local:8989"
echo "     API Key: from kubectl -n apps get secret sonarr-secret"
echo "5. Settings > Indexers > Add: Prowlarr auto-syncs to Radarr/Sonarr"
echo ""
echo "API Key (pre-configured): see kubectl -n apps get secret prowlarr-secret"
