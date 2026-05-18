#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"

# Clean up the service token secret created by post.sh (not tracked in YAML manifests)
for ns in base apps monitoring syncthing; do
    kubectl delete secret ntfy-service-token -n "$ns" --ignore-not-found 2>/dev/null || true
done
