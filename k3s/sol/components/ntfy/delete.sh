#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"

# Clean up the service token secret created by post.sh (not tracked in YAML manifests)
kubectl delete secret ntfy-service-token -n base --ignore-not-found 2>/dev/null || true
