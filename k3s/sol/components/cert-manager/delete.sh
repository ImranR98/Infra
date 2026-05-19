#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export VARS_ROOT="$(cd "$COMP_DIR/../../../.." >/dev/null 2>&1 && pwd)"
export TARGET="$(basename "$(cd "$COMP_DIR/../.." >/dev/null 2>&1 && pwd)")"
source "$VARS_ROOT/lib/vars.sh"

kubectl delete clusterissuer letsencrypt-staging letsencrypt-prod self-signed-issuer ca-issuer --ignore-not-found 2>/dev/null || true
kubectl delete certificate k3s-local-ca -n base --ignore-not-found 2>/dev/null || true
