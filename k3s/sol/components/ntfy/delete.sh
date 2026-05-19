#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export VARS_ROOT="$(cd "$COMP_DIR/../../../.." >/dev/null 2>&1 && pwd)"
export TARGET="$(basename "$(cd "$COMP_DIR/../.." >/dev/null 2>&1 && pwd)")"
source "$VARS_ROOT/lib/vars.sh"

# Clean up the service token secret created by post.sh (not tracked in YAML manifests)
for ns in $(kubectl get namespace -l pod-security.kubernetes.io/warn=baseline -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl delete secret ntfy-service-token -n "$ns" --ignore-not-found 2>/dev/null || true
done
