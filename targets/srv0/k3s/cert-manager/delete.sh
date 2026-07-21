#!/bin/bash
# DESC: Remove cluster issuers and certificates before deleting cert-manager
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

kubectl delete clusterissuer letsencrypt-staging letsencrypt-prod self-signed-issuer ca-issuer --ignore-not-found 2>/dev/null || true
kubectl delete certificate k3s-local-ca -n base --ignore-not-found 2>/dev/null || true
