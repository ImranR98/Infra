#!/bin/bash
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

echo "Waiting for system-upgrade-controller deployment..."
retry 60 5 "kubectl -n system-upgrade wait --for=condition=Available deployment/system-upgrade-controller --timeout=10s >/dev/null 2>&1"
