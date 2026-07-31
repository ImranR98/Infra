#!/bin/bash
set -euo pipefail

echo "=== FlareSolverr ==="
echo ""
echo "FlareSolverr is a proxy server to bypass Cloudflare protection."
echo "Internal service only — Prowlarr connects to:"
echo "  flaresolverr.apps.svc.cluster.local:8191"
echo ""
echo "In Prowlarr: Settings > Indexers > Add FlareSolverr"
echo "  URL: http://flaresolverr.apps.svc.cluster.local:8191"
